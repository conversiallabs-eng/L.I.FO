import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Confirmação de renovação pelo app (pós-PIX).
//
// O app chama DEPOIS que o polling detecta o pagamento no Asaas. A função:
//   1. autentica o usuário pelo JWT;
//   2. reconfere o pagamento DIRETO no Asaas (fonte da verdade) e amarra ao
//      usuário via externalReference (ou e-mail do customer);
//   3. aplica via fn_apply_payment (escritor único, idempotente, desconta a
//      confiança aberta: mensal 30d → libera 25d).
//
// O app NUNCA calcula expiração local — usa o expires_at devolvido aqui.
// Se a função estiver fora do ar, o webhook aplica depois; o app então só
// relê a assinatura do servidor.

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const CONFIRM_STATUS = new Set(["RECEIVED", "CONFIRMED", "RECEIVED_IN_CASH"]);

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    const asaasKey = Deno.env.get("ASAAS_API_KEY");
    if (!supabaseUrl || !serviceKey) throw new Error("Supabase env ausente.");
    if (!asaasKey) throw new Error("ASAAS_API_KEY ausente.");

    // ── Usuário pelo JWT ──
    const authHeader = req.headers.get("Authorization") ?? "";
    const jwtClient = createClient(
      supabaseUrl,
      Deno.env.get("SUPABASE_ANON_KEY") ?? serviceKey,
      { global: { headers: { Authorization: authHeader } } },
    );
    const { data: userData, error: userError } =
      await jwtClient.auth.getUser();
    const callerUid = userData?.user?.id;
    if (userError || !callerUid) {
      return new Response(JSON.stringify({ error: "não autenticado" }), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 401,
      });
    }

    const body = await req.json().catch(() => ({}));
    const paymentId = String(body?.payment_id ?? "");
    const provisionalAt = body?.provisional_granted_at
      ? String(body.provisional_granted_at)
      : null;
    if (!paymentId) throw new Error("payment_id é obrigatório.");

    const admin = createClient(supabaseUrl, serviceKey);

    // ── Confere no Asaas (com proxy de IP fixo, igual às outras funções) ──
    const baseUrl = Deno.env.get("ASAAS_BASE_URL") ?? "https://api.asaas.com/v3";
    const proxyUrl = Deno.env.get("ASAAS_PROXY_URL");
    const proxySecret = Deno.env.get("ASAAS_PROXY_SECRET") ?? "";

    async function asaasFetch(path: string): Promise<Response> {
      if (proxyUrl) {
        const sep = proxyUrl.includes("?") ? "&" : "?";
        return await fetch(`${proxyUrl}${sep}path=${encodeURIComponent(path)}`, {
          headers: {
            "Content-Type": "application/json",
            "access-token": asaasKey,
            "x-proxy-secret": proxySecret,
          },
        });
      }
      return await fetch(`${baseUrl}${path}`, {
        headers: { "Content-Type": "application/json", "access_token": asaasKey },
      });
    }

    const payRes = await asaasFetch(`/payments/${paymentId}`);
    const payment = await payRes.json().catch(() => ({}));
    const status = String(payment?.status ?? "").toUpperCase();
    if (!CONFIRM_STATUS.has(status)) {
      return new Response(
        JSON.stringify({ ok: false, confirmed: false, status }),
        {
          headers: { ...corsHeaders, "Content-Type": "application/json" },
          status: 200,
        },
      );
    }

    // ── Amarra o pagamento ao chamador ──
    let authUid: string | null =
      (payment?.externalReference as string | undefined) ?? null;
    if (!authUid && payment?.customer) {
      const cusRes = await asaasFetch(`/customers/${payment.customer}`);
      const customer = await cusRes.json().catch(() => ({}));
      const email = (customer?.email as string | undefined)?.toLowerCase();
      if (email) {
        const { data } = await admin
          .from("user_profiles")
          .select("auth_uid")
          .eq("email", email)
          .maybeSingle();
        authUid = (data?.auth_uid as string | undefined) ?? null;
      }
    }
    if (!authUid || authUid !== callerUid) {
      return new Response(
        JSON.stringify({ error: "pagamento não pertence a este usuário" }),
        {
          headers: { ...corsHeaders, "Content-Type": "application/json" },
          status: 403,
        },
      );
    }

    const priceCents = Math.round(Number(payment?.value ?? 0) * 100);

    const { data: applied, error: rpcError } = await admin.rpc(
      "fn_apply_payment",
      {
        p_asaas_payment_id: paymentId,
        p_user_id: authUid,
        p_value_cents: priceCents,
        p_source: "confirm",
        p_provisional_granted_at: provisionalAt,
      },
    );
    if (rpcError) throw new Error(`Falha ao aplicar pagamento: ${rpcError.message}`);

    return new Response(
      JSON.stringify({
        ok: true,
        confirmed: true,
        applied: (applied as any)?.applied ?? false,
        expires_at: (applied as any)?.expires_at ?? null,
        deducted_days: (applied as any)?.deducted_days ?? 0,
        days: (applied as any)?.days ?? 30,
        plan: (applied as any)?.plan ?? null,
        grace_rejected: (applied as any)?.grace_rejected ?? false,
      }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200,
      },
    );
  } catch (e: any) {
    return new Response(JSON.stringify({ error: e?.message ?? "confirm error" }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 400,
    });
  }
});
