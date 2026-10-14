import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function asaasErrorText(body: any, fallback: string): string {
  try {
    if (body?.errors && Array.isArray(body.errors) && body.errors.length > 0) {
      const parts = body.errors
        .map((e: any) => e?.description || e?.code || JSON.stringify(e))
        .filter(Boolean);
      if (parts.length > 0) return parts.join(" | ");
    }
    if (body?.error) return String(body.error);
    if (typeof body === "string" && body.trim()) return body.substring(0, 300);
  } catch (_) { /* ignora */ }
  return fallback;
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const asaasKey = Deno.env.get("ASAAS_API_KEY");
    if (!asaasKey) {
      throw new Error("ASAAS_API_KEY environment variable not set on Supabase.");
    }

    const { user_id, customer_name, customer_email, customer_cpf, customer_phone, value, description } = await req.json();

    // ── Validação espelho do app (mensagem clara antes do Asaas) ──
    const cpfDigits = String(customer_cpf ?? "").replace(/\D/g, "");
    if (cpfDigits.length !== 11 && cpfDigits.length !== 14) {
      throw new Error("CPF/CNPJ inválido. Atualize o cadastro antes de gerar o PIX.");
    }
    const email = String(customer_email ?? "").trim().toLowerCase();
    if (!email.includes("@") || !email.includes(".")) {
      throw new Error(`E-mail inválido no cadastro ("${customer_email ?? ""}"). Atualize em Minha Conta.`);
    }
    const name = String(customer_name ?? "").trim();
    if (name.length < 3) {
      throw new Error("Nome incompleto no cadastro. Atualize em Minha Conta.");
    }

    // Base URL configurável: ASAAS_BASE_URL (ex. sandbox https://sandbox.asaas.com/api/v3).
    // Padrão: produção https://api.asaas.com/v3
    const directBaseUrl = Deno.env.get("ASAAS_BASE_URL") ?? "https://api.asaas.com/v3";

    // Proxy de IP fixo (Hostinger 46.202.182.73) — contorna whitelist do Asaas.
    const proxyUrl = Deno.env.get("ASAAS_PROXY_URL");
    const proxySecret = Deno.env.get("ASAAS_PROXY_SECRET") ?? "";

    async function asaasFetch(path: string, init: RequestInit = {}): Promise<Response> {
      if (proxyUrl) {
        const headers = {
          "Content-Type": "application/json",
          "access-token": asaasKey,
          "User-Agent": "LIFO-Logistica-App/1.0",
          ...((init.headers as Record<string, string>) ?? {}),
        };
        const sep = proxyUrl.includes("?") ? "&" : "?";
        return await fetch(`${proxyUrl}${sep}path=${encodeURIComponent(path)}`, {
          ...init,
          headers: { ...headers, "x-proxy-secret": proxySecret },
        });
      }
      const headers = {
        "Content-Type": "application/json",
        "access_token": asaasKey,
        "User-Agent": "LIFO-Logistica-App/1.0",
        ...((init.headers as Record<string, string>) ?? {}),
      };
      return await fetch(`${directBaseUrl}${path}`, { ...init, headers });
    }

    // 1. Busca cliente por e-mail; se não achar, busca por CPF/CNPJ.
    // (Asaas exige cpfCnpj único: criar direto com CPF repetido dá 400.)
    let customerId = "";
    const searchEmailRes = await asaasFetch(`/customers?email=${encodeURIComponent(email)}`);
    if (!searchEmailRes.ok) {
      const t = await searchEmailRes.text();
      throw new Error(`Erro ao buscar cliente no Asaas (${searchEmailRes.status}): ${t.substring(0, 200)}`);
    }
    const searchEmailData = await searchEmailRes.json();

    if (searchEmailData.data && searchEmailData.data.length > 0) {
      customerId = searchEmailData.data[0].id;
      // Atualiza nome/CPF/telefone do cliente existente p/ não cobrar com dado velho.
      try {
        await asaasFetch(`/customers/${customerId}`, {
          method: "POST",
          body: JSON.stringify({
            name,
            email,
            cpfCnpj: cpfDigits,
            ...(customer_phone ? { mobilePhone: String(customer_phone).replace(/\D/g, "") } : {}),
          }),
        });
      } catch (_) { /* atualização é best-effort */ }
    } else {
      const searchCpfRes = await asaasFetch(`/customers?cpfCnpj=${encodeURIComponent(cpfDigits)}`);
      if (searchCpfRes.ok) {
        const searchCpfData = await searchCpfRes.json();
        if (searchCpfData.data && searchCpfData.data.length > 0) {
          customerId = searchCpfData.data[0].id;
          try {
            await asaasFetch(`/customers/${customerId}`, {
              method: "POST",
              body: JSON.stringify({ name, email }),
            });
          } catch (_) { /* best-effort */ }
        }
      }
    }

    if (!customerId) {
      const createCusRes = await asaasFetch(`/customers`, {
        method: "POST",
        body: JSON.stringify({
          name,
          email,
          cpfCnpj: cpfDigits,
          ...(customer_phone ? { mobilePhone: String(customer_phone).replace(/\D/g, "") } : {}),
        }),
      });
      const createCusData = await createCusRes.json().catch(async () => ({ raw: await createCusRes.text() }));
      if (!createCusData.id) {
        throw new Error(`Asaas recusou o cliente: ${asaasErrorText(createCusData, `HTTP ${createCusRes.status}`)}`);
      }
      customerId = createCusData.id;
    }

    // 2. Cria a cobrança PIX
    const dueDate = new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString().split("T")[0];
    const payRes = await asaasFetch(`/payments`, {
      method: "POST",
      body: JSON.stringify({
        customer: customerId,
        billingType: "PIX",
        value: value || 19.90,
        dueDate,
        description: description || "Assinatura LIFO Pro - 30 Dias",
        ...(user_id ? { externalReference: String(user_id) } : {}),
      }),
    });
    const payData = await payRes.json().catch(async () => ({ raw: await payRes.text() }));
    if (!payData.id) {
      throw new Error(`Asaas recusou a cobrança: ${asaasErrorText(payData, `HTTP ${payRes.status}`)}`);
    }

    // 3. Busca o QR Code e Copia e Cola do PIX
    const pixRes = await asaasFetch(`/payments/${payData.id}/pixQrCode`);
    const pixData = await pixRes.json().catch(async () => ({ raw: await pixRes.text() }));
    if (!pixData.payload) {
      throw new Error(
        `Cobrança ${payData.id} criada, mas o QR do PIX falhou: ${asaasErrorText(pixData, `HTTP ${pixRes.status}`)}. Tente "Já paguei / Confirmar" em instantes ou gere de novo.`,
      );
    }

    const responsePayload = {
      payment_id: payData.id,
      copy_and_paste_pix: pixData.payload,
      qr_code_base64: pixData.encodedImage,
      value: payData.value,
      expiration_date: pixData.expirationDate,
      status: payData.status,
    };

    return new Response(JSON.stringify(responsePayload), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 200,
    });
  } catch (error: any) {
    return new Response(JSON.stringify({ error: error.message }), {
      headers: { ...corsHeaders, "Content-Type": "application/json" },
      status: 400,
    });
  }
});
