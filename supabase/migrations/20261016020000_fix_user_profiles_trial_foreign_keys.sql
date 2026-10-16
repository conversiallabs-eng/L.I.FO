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

-- 5. Atualiza fn_start_trial com trava VITALÍCIA por CPF (único por pessoa para sempre)
CREATE OR REPLACE FUNCTION public.fn_start_trial(
  p_device_fingerprint text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_sub RECORD;
  v_prof RECORD;
  v_clean_cpf TEXT;
  v_abuse_found BOOLEAN := false;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no-auth', 'message', 'Não autenticado.');
  END IF;

  PERFORM set_config('app.money_writer', 'on', true);

  -- 1. Se já tem assinatura ativa ou passada para este usuário, retorna o status atual
  SELECT * INTO v_sub
  FROM public.subscriptions
  WHERE user_id = v_uid
  ORDER BY starts_at DESC
  LIMIT 1;

  IF FOUND THEN
    SELECT * INTO v_prof FROM public.user_profiles WHERE auth_uid = v_uid;
    RETURN jsonb_build_object(
      'ok', true,
      'trial', false,
      'expires_at', v_sub.expires_at,
      'plan', COALESCE(v_prof.plan, ''));
  END IF;

  -- 2. Busca o perfil do usuário: CPF É OBRIGATÓRIO PARA LIBERAR TRIAL
  SELECT * INTO v_prof FROM public.user_profiles WHERE auth_uid = v_uid;
  IF NOT FOUND OR v_prof.cpf IS NULL OR trim(v_prof.cpf) = '' THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'cpf_required',
      'message', 'É obrigatório informar o CPF para ativar o período de teste de 30 dias.'
    );
  END IF;

  v_clean_cpf := regexp_replace(v_prof.cpf, '\D', '', 'g');
  IF char_length(v_clean_cpf) <> 11 THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'cpf_invalid',
      'message', 'O CPF informado é inválido. Digite um CPF válido com 11 dígitos.'
    );
  END IF;

  -- 3. Trava Anti-Abuso Vitalícia:
  -- CPF só pode usar trial UMA ÚNICA VEZ NA VIDA (vitalício, sem expiração de tempo na auditoria).
  -- Aparelho físico bloqueado se já usou nos últimos 365 dias.
  SELECT EXISTS (
    SELECT 1 FROM public.trial_abuse_audit
    WHERE clean_cpf = v_clean_cpf
       OR (
         p_device_fingerprint IS NOT NULL
         AND p_device_fingerprint <> ''
         AND device_fingerprint = p_device_fingerprint
         AND trial_granted_at > (now() - interval '365 days')
       )
  ) INTO v_abuse_found;

  IF v_abuse_found THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'trial_already_used',
      'message', 'O período de teste gratuito de 30 dias é concedido apenas 1 vez por CPF (vitalício) e já foi utilizado. Assine um plano para continuar.'
    );
  END IF;

  -- 4. Concede o Trial na tabela de assinaturas oficial
  INSERT INTO public.subscriptions
    (user_id, plan_type, status, price_cents, starts_at, expires_at)
  VALUES (v_uid, 'trial', 'trialing', 0, now(), now() + interval '30 days');

  -- 5. Registra na auditoria histórica de hardware e CPF (para sempre)
  INSERT INTO public.trial_abuse_audit
    (user_id, clean_cpf, device_fingerprint, trial_expires_at)
  VALUES
    (v_uid, v_clean_cpf, COALESCE(p_device_fingerprint, 'unknown'), now() + interval '30 days');

  -- 6. Atualiza os dados do perfil do entregador
  UPDATE public.user_profiles
     SET plan = 'Standard (Trial 30 Dias)',
         expires_at = now() + interval '30 days',
         updated_at = now()
   WHERE auth_uid = v_uid;

  RETURN jsonb_build_object(
    'ok', true,
    'trial', true,
    'expires_at', now() + interval '30 days'
  );
END;
$$;

-- 6. Recarrega cache do PostgREST
NOTIFY pgrst, 'reload schema';
