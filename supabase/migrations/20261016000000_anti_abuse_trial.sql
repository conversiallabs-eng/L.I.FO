-- ============================================================================
-- L.I.F.O — BLINDAGEM DE RODÍZIO DE CONTAS & AUDITORIA DE TRIAL (100% IDEMPOTENTE)
-- ============================================================================
-- Resolve a vulnerabilidade de rodízio de contas (Google Auth e E-mail):
--   1. Cria índice de unicidade de CPF normalizado (apenas números) em user_profiles.
--   2. Adapta e garante a tabela de auditoria por CPF e Aparelho Físico (12 meses).
--   3. Atualiza fn_start_trial para exigir CPF válido e bloquear reutilização de trial.
-- ============================================================================

-- 1. Garante que ninguém use o mesmo CPF em contas diferentes -----------------
CREATE UNIQUE INDEX IF NOT EXISTS uq_user_profiles_clean_cpf
ON public.user_profiles (regexp_replace(cpf, '\D', '', 'g'))
WHERE cpf IS NOT NULL AND trim(cpf) <> '';

-- 2. Tabela histórica de auditoria de trial (Anti-Rodízio por Hardware + CPF) --
CREATE TABLE IF NOT EXISTS public.trial_abuse_audit (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID,
    clean_cpf TEXT,
    device_fingerprint TEXT,
    trial_granted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    trial_expires_at TIMESTAMPTZ NOT NULL DEFAULT (now() + interval '30 days')
);

-- Compatibilidade: se a tabela já existia com schema antigo (cpf_hash / FK de profiles):
ALTER TABLE public.trial_abuse_audit ADD COLUMN IF NOT EXISTS clean_cpf TEXT;
ALTER TABLE public.trial_abuse_audit ADD COLUMN IF NOT EXISTS device_fingerprint TEXT;
ALTER TABLE public.trial_abuse_audit ADD COLUMN IF NOT EXISTS trial_granted_at TIMESTAMPTZ NOT NULL DEFAULT now();
ALTER TABLE public.trial_abuse_audit ADD COLUMN IF NOT EXISTS trial_expires_at TIMESTAMPTZ NOT NULL DEFAULT (now() + interval '30 days');

DO $$
BEGIN
  -- Se cpf_hash existia, desativa NOT NULL e migra dados para clean_cpf
  IF EXISTS (
    SELECT 1 FROM information_schema.columns 
    WHERE table_schema = 'public' AND table_name = 'trial_abuse_audit' AND column_name = 'cpf_hash'
  ) THEN
    ALTER TABLE public.trial_abuse_audit ALTER COLUMN cpf_hash DROP NOT NULL;
    UPDATE public.trial_abuse_audit SET clean_cpf = cpf_hash WHERE clean_cpf IS NULL;
  END IF;
END $$;

-- Remove qualquer Foreign Key antiga restritiva que apontava para public.profiles
DO $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN (
    SELECT tc.constraint_name
    FROM information_schema.table_constraints tc
    WHERE tc.table_schema = 'public'
      AND tc.table_name = 'trial_abuse_audit'
      AND tc.constraint_type = 'FOREIGN KEY'
  ) LOOP
    EXECUTE 'ALTER TABLE public.trial_abuse_audit DROP CONSTRAINT IF EXISTS ' || quote_ident(r.constraint_name);
  END LOOP;
END $$;

CREATE INDEX IF NOT EXISTS idx_trial_clean_cpf ON public.trial_abuse_audit(clean_cpf);
CREATE INDEX IF NOT EXISTS idx_trial_device_fp ON public.trial_abuse_audit(device_fingerprint);

-- RLS: Segurança das auditorias
ALTER TABLE public.trial_abuse_audit ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view own trial audit" ON public.trial_abuse_audit;
CREATE POLICY "Users can view own trial audit"
  ON public.trial_abuse_audit FOR SELECT
  USING (auth.uid() = user_id);

-- 3. Função atômica de validação e concessão de Trial -------------------------
CREATE OR REPLACE FUNCTION public.fn_start_trial(
  p_device_fingerprint TEXT DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
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

  -- 3.1 Se já tem assinatura ativa ou passada para este usuário, retorna o status atual
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

  -- 3.2 Busca o perfil do usuário: CPF É OBRIGATÓRIO PARA LIBERAR TRIAL
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

  -- 3.3 Trava Anti-Rodízio: Checa se o CPF OU o Celular físico já usaram trial nos últimos 12 meses
  SELECT EXISTS (
    SELECT 1 FROM public.trial_abuse_audit
    WHERE (
      clean_cpf = v_clean_cpf
      OR (p_device_fingerprint IS NOT NULL AND p_device_fingerprint <> '' AND device_fingerprint = p_device_fingerprint)
    )
    AND trial_granted_at > (now() - interval '365 days')
  ) INTO v_abuse_found;

  IF v_abuse_found THEN
    RETURN jsonb_build_object(
      'ok', false,
      'reason', 'trial_already_used',
      'message', 'O período de teste gratuito de 30 dias já foi utilizado neste CPF ou aparelho nos últimos 12 meses. Assinatura imediata necessária.'
    );
  END IF;

  -- 3.4 Concede o Trial na tabela de assinaturas oficial
  INSERT INTO public.subscriptions
    (user_id, plan_type, status, price_cents, starts_at, expires_at)
  VALUES (v_uid, 'trial', 'trialing', 0, now(), now() + interval '30 days');

  -- 3.5 Registra na auditoria histórica de hardware e CPF
  INSERT INTO public.trial_abuse_audit
    (user_id, clean_cpf, device_fingerprint, trial_expires_at)
  VALUES
    (v_uid, v_clean_cpf, COALESCE(p_device_fingerprint, 'unknown'), now() + interval '30 days');

  -- 3.6 Atualiza os dados do perfil do entregador
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

GRANT EXECUTE ON FUNCTION public.fn_start_trial(TEXT) TO authenticated;
