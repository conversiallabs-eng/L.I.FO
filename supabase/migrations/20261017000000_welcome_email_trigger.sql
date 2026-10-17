-- ============================================================================
-- TRIGGER AUTOMÁTICO: ENVIAR E-MAIL DE BOAS-VINDAS PARA NOVOS USUÁRIOS (RESEND)
-- ============================================================================

-- 1. Habilita a extensão pg_net (nativa do Supabase para chamadas HTTP assíncronas)
CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;

-- 2. Função disparada no INSERT de novos usuários em auth.users
CREATE OR REPLACE FUNCTION public.handle_new_user_welcome_email()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, extensions
AS $$
DECLARE
  v_supabase_url TEXT;
  v_service_role_key TEXT;
  v_request_id BIGINT;
BEGIN
  -- Apenas se tiver e-mail válido
  IF NEW.email IS NOT NULL AND NEW.email <> '' THEN
    
    -- Busca a URL do Supabase configurada ou fallback padrão do projeto sjbmweuszwxbkdimbwdg
    v_supabase_url := 'https://sjbmweuszwxbkdimbwdg.supabase.co';
    
    -- Dispara a Edge Function send-welcome-email em background via pg_net
    SELECT net.http_post(
      url := v_supabase_url || '/functions/v1/send-welcome-email',
      headers := jsonb_build_object(
        'Content-Type', 'application/json'
      ),
      body := jsonb_build_object(
        'record', jsonb_build_object(
          'id', NEW.id,
          'email', NEW.email,
          'full_name', NEW.raw_user_meta_data->>'full_name'
        )
      ),
      timeout_milliseconds := 10000
    ) INTO v_request_id;
    
  END IF;

  RETURN NEW;
EXCEPTION
  WHEN OTHERS THEN
    -- Nunca bloqueia a criação do usuário se a chamada HTTP falhar
    RAISE WARNING 'Falha ao agendar e-mail de boas-vindas: %', SQLERRM;
    RETURN NEW;
END;
$$;

-- 3. Cria o Trigger em auth.users
DROP TRIGGER IF EXISTS on_auth_user_created_send_welcome ON auth.users;

CREATE TRIGGER on_auth_user_created_send_welcome
  AFTER INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.handle_new_user_welcome_email();
