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

    const { payment_id } = await req.json();
    if (!payment_id) {
      throw new Error("payment_id is required.");
    }

    // Proxy de IP fixo (Hostinger 46.202.182.73) — mesmo esquema da create-asaas-pix-charge.
    const proxyUrl = Deno.env.get("ASAAS_PROXY_URL");
    const proxySecret = Deno.env.get("ASAAS_PROXY_SECRET") ?? "";
    const directBaseUrl = "https://api.asaas.com/v3";

    async function asaasFetch(path: string): Promise<Response> {
      if (proxyUrl) {
        // Via proxy: usa access-token (com traco) porque CDN/nginx derruba header com underscore
        return await fetch(`${proxyUrl}${(proxyUrl.includes("?") ? "&" : "?")}path=${encodeURIComponent(path)}`, {
          headers: {
            "Content-Type": "application/json",
            "access-token": asaasKey,
            "User-Agent": "LIFO-Logistica-App/1.0",
            "x-proxy-secret": proxySecret,
          },
        });
      }
      const headers = {
        "Content-Type": "application/json",
        "access_token": asaasKey,
        "User-Agent": "LIFO-Logistica-App/1.0",
      };
      return await fetch(`${directBaseUrl}${path}`, { headers });
    }

    const payRes = await asaasFetch(`/payments/${payment_id}`);
    const payData = await payRes.json();

    return new Response(JSON.stringify({ status: payData.status }), {
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
