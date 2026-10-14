import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const asaasKey = Deno.env.get("ASAAS_API_KEY");
    if (!asaasKey) {
      throw new Error("ASAAS_API_KEY environment variable not set on Supabase.");
    }

    const { user_id, customer_name, customer_email, customer_cpf, value, description } = await req.json();

    // Proxy de IP fixo (Hostinger 46.202.182.73) — contorna whitelist do Asaas.
    // Se ASAAS_PROXY_URL estiver setada, todo tráfego sai pelo IP fixo.
    // Ex: ASAAS_PROXY_URL=https://seudominio.com/asaas-proxy.php
    const proxyUrl = Deno.env.get("ASAAS_PROXY_URL");
    const proxySecret = Deno.env.get("ASAAS_PROXY_SECRET") ?? "";
    const directBaseUrl = "https://api.asaas.com/v3";

    async function asaasFetch(path: string, init: RequestInit = {}): Promise<Response> {
      const headers = {
        "Content-Type": "application/json",
        "access_token": asaasKey,
        "User-Agent": "LIFO-Logistica-App/1.0",
        ...((init.headers as Record<string, string>) ?? {}),
      };
      if (proxyUrl) {
        const sep = proxyUrl.includes("?") ? "&" : "?";
        return await fetch(`${proxyUrl}${sep}path=${encodeURIComponent(path)}`, {
          ...init,
          headers: { ...headers, "x-proxy-secret": proxySecret },
        });
      }
      return await fetch(`${directBaseUrl}${path}`, { ...init, headers });
    }

    // 1. Busca ou cria o cliente no Asaas
    let customerId = "";
    const searchRes = await asaasFetch(`/customers?email=${encodeURIComponent(customer_email)}`);
    const searchData = await searchRes.json();

    if (searchData.data && searchData.data.length > 0) {
      customerId = searchData.data[0].id;
    } else {
      const createCusRes = await asaasFetch(`/customers`, {
        method: "POST",
        body: JSON.stringify({
          name: customer_name || "Cliente LIFO",
          email: customer_email,
          cpfCnpj: customer_cpf || undefined,
        }),
      });
      const createCusData = await createCusRes.json();
      if (!createCusData.id) {
        throw new Error(createCusData.errors?.[0]?.description || createCusData.error || "Erro ao criar cliente no Asaas.");
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
      }),
    });
    const payData = await payRes.json();
    if (!payData.id) {
      throw new Error(payData.errors?.[0]?.description || payData.error || "Erro ao criar cobrança PIX no Asaas.");
    }

    // 3. Busca o QR Code e Copia e Cola do PIX
    const pixRes = await asaasFetch(`/payments/${payData.id}/pixQrCode`);
    const pixData = await pixRes.json();

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
