-- ============================================================================
-- Fix user_profiles expires_at default & subscriptions foreign key constraint
-- ============================================================================

-- 1. Garante que novos perfis nascem com ZERO dias (Pendente de Ativação / now())
-- Os 30 dias SÓ podem ser liberados pela função fn_start_trial após validação de CPF!
ALTER TABLE public.user_profiles ALTER COLUMN plan SET DEFAULT 'Pendente de Ativação';
ALTER TABLE public.user_profiles ALTER COLUMN expires_at SET DEFAULT now();
ALTER TABLE public.user_profiles ALTER COLUMN expires_at DROP NOT NULL;

-- 2. Corrige FK de subscriptions para apontar para auth.users(id)
ALTER TABLE public.subscriptions DROP CONSTRAINT IF EXISTS subscriptions_user_id_fkey;
ALTER TABLE public.subscriptions 
  ADD CONSTRAINT subscriptions_user_id_fkey 
  FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

-- 3. Remove sobrecarga antiga de fn_start_trial sem parâmetros
DROP FUNCTION IF EXISTS public.fn_start_trial();

-- 4. Atualiza trg_guard_money para aceitar 'Pendente de Ativação' no INSERT de novos perfis
CREATE OR REPLACE FUNCTION public.trg_guard_money()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  v_bypass boolean :=
    current_user IN ('service_role', 'postgres') OR
    current_setting('app.money_writer', true) = 'on';
BEGIN
  IF v_bypass THEN
    RETURN NEW;
  END IF;

  IF TG_TABLE_NAME = 'subscriptions' THEN
    IF NEW.plan_type IS DISTINCT FROM 'trial'
       OR NEW.status IS DISTINCT FROM 'trialing'
       OR COALESCE(NEW.price_cents, 0) != 0
       OR NEW.expires_at > now() + interval '31 days' THEN
      RAISE EXCEPTION 'assinatura paga só via servidor (use o PIX no app)'
        USING ERRCODE = '42501';
    END IF;
  ELSIF TG_TABLE_NAME = 'user_profiles' THEN
    IF TG_OP = 'UPDATE'
       AND (NEW.plan IS DISTINCT FROM OLD.plan
            OR NEW.expires_at IS DISTINCT FROM OLD.expires_at) THEN
      RAISE EXCEPTION 'plano/expiração só via servidor'
        USING ERRCODE = '42501';
    END IF;
    IF TG_OP = 'INSERT'
       AND (NEW.plan NOT ILIKE '%trial%' AND NEW.plan NOT ILIKE '%pendente%') THEN
      RAISE EXCEPTION 'plano inicial inválido'
        USING ERRCODE = '42501';
    END IF;
    IF TG_OP = 'INSERT'
       AND NEW.expires_at > now() + interval '31 days' THEN
      RAISE EXCEPTION 'validade inicial inválida'
        USING ERRCODE = '42501';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

-- 5. Recarrega cache do PostgREST
NOTIFY pgrst, 'reload schema';
