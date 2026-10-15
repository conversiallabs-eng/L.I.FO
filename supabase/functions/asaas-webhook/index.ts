import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Webhook do Asaas → ativação AUTOMÁTICA da assinatura (sem botão manual).
//
// Cadastro no Asaas (Cobranças → Integrações → Webhooks):
//   URL: https://sjbmweuszwxbkdimbwdg.supabase.co/functions/v1/asaas-webhook?token=<ASAAS_WEBHOOK_TOKEN>
//   Eventos: Pagamento recebido + Pagamento confirmado
//   Versão: v3
//
// O token é comparado com o secret ASAAS_WEBHOOK_TOKEN (definido via
// `supabase secrets set`). Se o secret não existir, aceita sem checar
// (útil no 1º teste — mas configure o secret em produção).

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const CONFIRM_EVENTS = new Set([
  "PAYMENT_RECEIVED",
  "PAYMENT_CONFIRMED",
  "PAYMENT_RECEIVED_IN_CASH",
]);

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    // ── Autenticação simples por token ──
    const expected = Deno.env.get("ASAAS_WEBHOOK_TOKEN") ?? "";
    if (expected) {
      const got = new URL(req.url).searchParams.get("token") ?? "";
      if (got !== expected) {
        return new Response(JSON.stringify({ error: "unauthorized" }), {
          headers: { ...corsHeaders, "Content-Type": "application/json" },
          status: 401,
        });
      }
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseUrl || !serviceKey) {
      throw new Error("Supabase env ausente na Edge Function.");
    }
    const admin = createClient(supabaseUrl, serviceKey);

    const body = await req.json().catch(() => ({}));
    const event = String(body?.event ?? "").toUpperCase();
    const paymentId = body?.payment?.id as string | undefined;

    // Responde 200 p/ eventos irrelevantes (Asaas para de retentar).
    if (!CONFIRM_EVENTS.has(event) || !paymentId) {
      return new Response(JSON.stringify({ ok: true, ignored: event || "no-event" }), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200,
      });
    }

    // ── Confere o pagamento direto no Asaas (fonte da verdade) ──
    const asaasKey = Deno.env.get("ASAAS_API_KEY");
    if (!asaasKey) throw new Error("ASAAS_API_KEY ausente.");
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
    if (status !== "RECEIVED" && status !== "CONFIRMED" && status !== "RECEIVED_IN_CASH") {
      return new Response(JSON.stringify({ ok: true, pending: status }), {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200,
      });
    }

    // ── Descobre o usuário: externalReference (user_id) → e-mail ──
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
    if (!authUid) throw new Error("Usuário não identificado no pagamento.");

    // ── Escritor único: fn_apply_payment (idempotente, desconta confiança) ──
    // Acaba o duplo-crédito (app somava +30 local e o webhook somava +30).
    const paidValue = Number(payment?.value ?? 0);
    const priceCents = Math.round(paidValue * 100);

    const { data: applied, error: rpcError } = await admin.rpc(
      "fn_apply_payment",
      {
        p_asaas_payment_id: paymentId,
        p_user_id: authUid,
        p_value_cents: priceCents,
        p_source: "webhook",
        p_provisional_granted_at: null,
      },
    );
    if (rpcError) throw new Error(`Falha ao ativar assinatura: ${rpcError.message}`);

    return new Response(
      JSON.stringify({
        ok: true,
        user_id: authUid,
        applied: (applied as any)?.applied ?? false,
        expires_at: (applied as any)?.expires_at ?? null,
        deducted_days: (applied as any)?.deducted_days ?? 0,
      }),
      {
        headers: { ...corsHeaders, "Content-Type": "application/json" },
        status: 200,
      },
    );
  } catch (e: any) {
    // 200 mesmo em erro interno? Não — 500 faz o Asaas retentar (bom).
    return new Response(JSON.stringify({ error: e?.message ?? "webhook error" }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 500,
    });
  }
});
