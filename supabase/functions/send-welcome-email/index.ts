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
    const resendApiKey = Deno.env.get("RESEND_API_KEY");
    if (!resendApiKey) {
      throw new Error("RESEND_API_KEY não configurada no Supabase.");
    }

    const payload = await req.json().catch(() => ({}));
    
    // Suporte tanto a chamada direta quanto a payload do Supabase Database Webhook (record)
    const record = payload.record ?? payload;
    const email = record.email;
    
    if (!email) {
      return new Response(JSON.stringify({ error: "E-mail ausente no payload" }), {
        status: 400,
        headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const htmlContent = `<!DOCTYPE html>
<html>
<head>
<meta charset='utf-8'>
<meta name='viewport' content='width=device-width, initial-scale=1.0'>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; background-color: #f1f5f9; margin: 0; padding: 24px 12px; color: #0f172a; }
  .container { max-width: 580px; margin: 0 auto; background: #ffffff; border-radius: 16px; overflow: hidden; border: 1px solid #cbd5e1; box-shadow: 0 8px 30px rgba(0,0,0,0.08); }
  
  /* Azul Oficial L.I.F.O */
  .header { background: linear-gradient(135deg, #0052cc 0%, #0066FF 50%, #2979FF 100%); padding: 36px 24px; text-align: center; }
  .header h1 { color: #ffffff; margin: 0; font-size: 30px; font-weight: 900; letter-spacing: 2px; }
  .header p { color: #dbeafe; margin: 8px 0 0; font-size: 13.5px; font-weight: 600; text-transform: uppercase; letter-spacing: 1px; }
  
  .content { padding: 32px 28px; line-height: 1.65; font-size: 15px; color: #1e293b; }
  .greeting { font-size: 20px; font-weight: 800; color: #0066FF; margin-bottom: 14px; }
  
  .feature-box { background: #ffffff; border: 2px solid #e2e8f0; border-radius: 14px; padding: 20px; margin: 22px 0; box-shadow: 0 2px 8px rgba(0,0,0,0.02); }
  .feature-item { margin-bottom: 16px; }
  .feature-item:last-child { margin-bottom: 0; }
  .feature-title { font-weight: 800; color: #0f172a; font-size: 15px; margin-bottom: 4px; }
  .feature-desc { font-size: 13.5px; color: #475569; margin: 0; line-height: 1.5; }

  .whatsapp-btn { display: inline-block; background-color: #25D366; color: #ffffff !important; text-decoration: none; font-weight: 800; padding: 15px 28px; border-radius: 10px; margin: 18px 0; font-size: 15px; box-shadow: 0 4px 14px rgba(37,211,102,0.35); text-align: center; }
  
  .security-note { background: #f8fafc; border: 1px dashed #cbd5e1; border-radius: 10px; padding: 14px 16px; margin-top: 28px; font-size: 12.5px; color: #64748b; line-height: 1.5; }
  .security-title { font-weight: 700; color: #334155; margin-bottom: 4px; display: flex; align-items: center; }

  .footer { border-top: 1px solid #e2e8f0; padding: 20px; text-align: center; font-size: 13px; color: #64748b; background: #f8fafc; }
</style>
</head>
<body>
  <div class='container'>
    <div class='header'>
      <h1>L.I.F.O</h1>
      <p>Last In, First Out &bull; Feito por quem vive a rotina</p>
    </div>
    <div class='content'>
      <div class='greeting'>Ol&aacute;, que bom ter voc&ecirc; por aqui!</div>
      
      <p>Queria te dar as boas-vindas pessoalmente.</p>
      
      <p>Eu tamb&eacute;m sou entregador, já trabalhei na Shopee e enfrentei na pele as falhas dos aplicativos tradicionais: sistemas engessados, rotas confusas e a falta de recursos pr&aacute;ticos que realmente ajudam no dia a dia. Por isso, decidi criar o <strong>L.I.F.O</strong>.</p>
      
      <p>O nome vem de <em>Last In, First Out</em> (o &uacute;ltimo pacote que entra &eacute; o primeiro que sai). O app foi pensado diretamente para resolver os desafios reais da nossa rotina:</p>

      <div class='feature-box'>
        <div class='feature-item'>
          <div class='feature-title'>&#128247;&nbsp; Bipador de Etiqueta com Busca Autom&aacute;tica</div>
          <p class='feature-desc'>Achou um pacote no veículo e não sabe onde entregar? Basta bipar o c&oacute;digo de barras ou QR code da etiqueta com a c&acirc;mera do app. O L.I.F.O localiza a parada, mostra os dados do cliente e tra&ccedil;a a rota na hora &mdash; sem precisar procurar na lista.</p>
        </div>

        <div class='feature-item' style='border-top: 1px solid #f1f5f9; padding-top: 14px;'>
          <div class='feature-title'>&#128260;&nbsp; Backup Autom&aacute;tico de Rotas &amp; Organizador de Carga</div>
          <p class='feature-desc'>Se você precisar reotimizar seu trajeto, o L.I.F.O mantém sua rota anterior salva em backup, evitando desorganizar seus pacotes. E se a carga se misturar, o organizador e o leitor de etiquetas colocam tudo em ordem em segundos.</p>
        </div>
      </div>

      <p>Não queremos que o L.I.F.O seja apenas mais um aplicativo no seu telefone, mas sim o seu principal parceiro de trabalho.</p>

      <p>Qualquer d&uacute;vida, sugest&atilde;o de melhoria ou relato de problema, <strong>fale comigo diretamente no WhatsApp:</strong></p>

      <div style='text-align: center;'>
        <a href='https://wa.me/5548935013889' class='whatsapp-btn' target='_blank'>
          &#128242; Falar no WhatsApp: (48) 93501-3889
        </a>
      </div>

      <p style='font-size: 13.5px; color: #64748b;'>Pode mandar mensagem, &aacute;udio ou print de tela. Faço questão de responder pessoalmente cada parceiro.</p>

      <!-- Nota de Transparência e Pagamento Oficial -->
      <div class='security-note'>
        <div class='security-title'>&#128274; Nota de Transpar&ecirc;ncia &amp; Pagamentos Oficiais</div>
        Informamos que todo pagamento oficial de assinatura ou renovação do L.I.F.O é processado com total segurança através da plataforma Asaas e é emitido exclusivamente em nome de <strong>Ronaldo de Almeida Arruda (Asaas I.P. S.A.)</strong>.
      </div>

      <p style='margin-top: 24px;'>Espero de verdade que o L.I.F.O traga muito mais agilidade e tranquilidade para o seu trabalho.<br>
      <strong>Tenha um &oacute;timo dia e excelentes entregas! &#128074;&#128230;</strong></p>

      <p style='margin-bottom: 0;'><strong>Equipe L.I.F.O</strong></p>
    </div>
    <div class='footer'>
      &copy; 2026 L.I.F.O &bull; Feito por entregadores, para entregadores.
    </div>
  </div>
</body>
</html>`;

    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${resendApiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        from: "L.I.F.O <contato@lifo.com.br>",
        to: [email],
        subject: "Bem-vindo ao L.I.F.O! 📦🚀 (Uma mensagem do criador)",
        html: htmlContent,
      }),
    });

    const resData = await res.json();
    return new Response(JSON.stringify(resData), {
      status: res.status,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (err: any) {
    return new Response(JSON.stringify({ error: err.message }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
