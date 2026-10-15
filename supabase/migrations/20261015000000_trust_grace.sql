-- ============================================================================
-- L.I.F.O — Confiança ("libere e pague") com ledger 100% no servidor
-- ============================================================================
-- REGRA DE NEGÓCIO (anti-calote):
--   1. Confiança (+5 dias) só para quem PAGOU pelo menos 1x (payment_events).
--   2. Só vale 1x por ciclo: com graça ABERTA não há nova concessão; pagar
--      marca a graça como quitada (e a renovação desconta os dias adiantados:
--      mensal 30d → libera 25d).
--   3. Cliente nunca escreve dinheiro: trigger trg_guard_money barra
--      plan/expires de user_profiles e qualquer linha não-trial de
--      subscriptions quando quem escreve é o próprio usuário (auth.uid()).
--      Escritas do servidor (webhook/service_role e funções com GUC
--      app.money_writer=on) passam.
--   4. Pagamento tem escritor único idempotente: fn_apply_payment
--      (chamado pelo webhook e pelo confirm-renewal). Acaba o duplo-crédito
--      (app somava +30 local e o webhook somava +30 de novo).
--
-- COMO APLICAR:
--   A) CLI:  supabase db push --linked   (pede a senha do banco)
--   B) Dashboard: cole este arquivo em
--      https://supabase.com/dashboard/project/sjbmweuszwxbkdimbwdg/sql  e RUN.
-- Idempotente: pode rodar quantas vezes quiser.
-- ============================================================================

-- ── 1. Ledger de pagamentos confirmados (fonte do "pagou 1x") ───────────────
CREATE TABLE IF NOT EXISTS public.payment_events (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id           UUID NOT NULL,
  asaas_payment_id  TEXT NOT NULL,
  value_cents       INTEGER NOT NULL DEFAULT 0,
  days              INTEGER NOT NULL DEFAULT 30,
  status            TEXT NOT NULL DEFAULT 'confirmed',
  source            TEXT NOT NULL DEFAULT 'webhook',
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_payment_events_asaas UNIQUE (asaas_payment_id)
);
CREATE INDEX IF NOT EXISTS idx_payment_events_user
  ON public.payment_events (user_id);

ALTER TABLE public.payment_events ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Users can view own payment_events" ON public.payment_events;
CREATE POLICY "Users can view own payment_events"
  ON public.payment_events FOR SELECT
  USING (auth.uid() = user_id);
-- Sem INSERT/UPDATE/DELETE por cliente: só o servidor escreve.

-- ── 2. Ledger da confiança (graças concedidas) ──────────────────────────────
CREATE TABLE IF NOT EXISTS public.trust_graces (
  id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id                UUID NOT NULL,
  granted_at             TIMESTAMPTZ NOT NULL DEFAULT now(),
  device_granted_at      TIMESTAMPTZ,
  days                   INTEGER NOT NULL DEFAULT 5,
  status                 TEXT NOT NULL DEFAULT 'open', -- open | repaid | void
  repaid_at              TIMESTAMPTZ,
  repaid_payment_event_id UUID REFERENCES public.payment_events(id),
  created_at             TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_trust_graces_user
  ON public.trust_graces (user_id);
CREATE INDEX IF NOT EXISTS idx_trust_graces_open
  ON public.trust_graces (user_id) WHERE status = 'open';

ALTER TABLE public.trust_graces ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "Users can view own trust_graces" ON public.trust_graces;
CREATE POLICY "Users can view own trust_graces"
  ON public.trust_graces FOR SELECT
  USING (auth.uid() = user_id);
-- Sem escrita por cliente: só via fn_trust_grace_grant / fn_apply_payment.

-- ── 3. Backfill: quem já pagou (subscriptions com valor) conta como pago ───
INSERT INTO public.payment_events
  (user_id, asaas_payment_id, value_cents, days, status, source)
SELECT
  user_id,
  'backfill-' || id::text,
  price_cents,
  CASE WHEN price_cents >= 19900 THEN 365 ELSE 30 END,
  'confirmed',
  'backfill'
FROM public.subscriptions
WHERE price_cents > 0
ON CONFLICT (asaas_payment_id) DO NOTHING;

-- ── 4. Status da confiança (elegível? por quê?) ─────────────────────────────
CREATE OR REPLACE FUNCTION public.fn_trust_grace_status()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid   uuid := auth.uid();
  v_paid  int := 0;
  v_open  jsonb := NULL;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('eligible', false, 'reason', 'no-auth');
  END IF;

  SELECT count(*) INTO v_paid
  FROM public.payment_events
  WHERE user_id = v_uid AND status = 'confirmed';

  SELECT jsonb_build_object(
           'id', id,
           'granted_at', granted_at,
           'days', days,
           'expires_at', granted_at + (days || ' days')::interval
         )
    INTO v_open
  FROM public.trust_graces
  WHERE user_id = v_uid AND status = 'open'
  ORDER BY granted_at DESC
  LIMIT 1;

  IF v_paid < 1 THEN
    RETURN jsonb_build_object(
      'eligible', false, 'reason', 'never-paid', 'paid_count', v_paid);
  END IF;
  IF v_open IS NOT NULL THEN
    RETURN jsonb_build_object(
      'eligible', false, 'reason', 'grace-open',
      'paid_count', v_paid, 'open_grace', v_open);
  END IF;
  RETURN jsonb_build_object('eligible', true, 'paid_count', v_paid);
END;
$$;

-- ── 5. Concessão / reconciliação (idempotente: aberta existente é devolvida) ─
CREATE OR REPLACE FUNCTION public.fn_trust_grace_grant(
  p_device_granted_at timestamptz DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid   uuid := auth.uid();
  v_paid  int := 0;
  v_open  RECORD;
  v_eff   timestamptz;
  v_days  int := 5;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no-auth');
  END IF;

  SELECT count(*) INTO v_paid
  FROM public.payment_events
  WHERE user_id = v_uid AND status = 'confirmed';
  IF v_paid < 1 THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'never-paid');
  END IF;

  SELECT * INTO v_open
  FROM public.trust_graces
  WHERE user_id = v_uid AND status = 'open'
  ORDER BY granted_at DESC
  LIMIT 1;
  IF FOUND THEN
    -- Já há adiantamento aberto: não duplica; a renovação desconta dele.
    RETURN jsonb_build_object(
      'ok', true, 'already', true,
      'granted_at', v_open.granted_at,
      'days', v_open.days,
      'expires_at', v_open.granted_at + (v_open.days || ' days')::interval);
  END IF;

  -- Hora efetiva: alegação do aparelho se plausível (±24h), senão agora.
  v_eff := now();
  IF p_device_granted_at IS NOT NULL
     AND abs(extract(epoch FROM (now() - p_device_granted_at))) < 86400 THEN
    v_eff := p_device_granted_at;
  END IF;

  INSERT INTO public.trust_graces (user_id, granted_at, device_granted_at, days, status)
  VALUES (v_uid, v_eff, p_device_granted_at, v_days, 'open');

  RETURN jsonb_build_object(
    'ok', true, 'already', false,
    'granted_at', v_eff,
    'days', v_days,
    'expires_at', v_eff + (v_days || ' days')::interval);
END;
$$;

-- ── 6. Aplicação de pagamento (ESCRITOR ÚNICO, idempotente) ─────────────────
-- Chamado pelo webhook e pelo confirm-renewal. Desconta graça aberta.
CREATE OR REPLACE FUNCTION public.fn_apply_payment(
  p_asaas_payment_id  text,
  p_user_id           uuid DEFAULT NULL,
  p_value_cents       int DEFAULT 0,
  p_source            text DEFAULT 'webhook',
  p_provisional_granted_at timestamptz DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid      uuid := COALESCE(p_user_id, auth.uid());
  v_days     int;
  v_evt_id   uuid;
  v_open     RECORD;
  v_has_open boolean := false;
  v_deduct   int := 0;
  v_sub      RECORD;
  v_has_sub  boolean := false;
  v_base     timestamptz;
  v_new      timestamptz;
  v_plan     text;
  v_rejected boolean := false;
BEGIN
  IF v_uid IS NULL OR p_asaas_payment_id IS NULL OR p_asaas_payment_id = '' THEN
    RETURN jsonb_build_object('applied', false, 'reason', 'bad-args');
  END IF;

  PERFORM set_config('app.money_writer', 'on', true);

  v_days := CASE WHEN p_value_cents >= 19900 THEN 365 ELSE 30 END;

  -- Idempotência: pagamento já aplicado (webhook x app concorrentes)?
  SELECT id INTO v_evt_id
  FROM public.payment_events
  WHERE asaas_payment_id = p_asaas_payment_id;
  IF FOUND THEN
    SELECT * INTO v_sub
    FROM public.subscriptions
    WHERE user_id = v_uid
    ORDER BY expires_at DESC
    LIMIT 1;
    RETURN jsonb_build_object(
      'applied', false, 'reason', 'already-applied',
      'expires_at', CASE WHEN FOUND THEN v_sub.expires_at ELSE NULL END,
      'deducted_days', 0);
  END IF;

  -- Reconcilia graça provisória (concedida offline) ANTES de registrar o pago.
  IF p_provisional_granted_at IS NOT NULL THEN
    PERFORM 1 FROM public.payment_events
     WHERE user_id = v_uid AND status = 'confirmed';
    IF NOT FOUND THEN
      -- Histórico anterior não existe: este próprio pagamento qualifica?
      -- Não: a regra exige ter pago ANTES. Rejeita a provisória.
      v_rejected := true;
    ELSE
      PERFORM 1 FROM public.trust_graces
       WHERE user_id = v_uid AND status = 'open';
      IF NOT FOUND THEN
        INSERT INTO public.trust_graces (user_id, granted_at, device_granted_at, days, status)
        VALUES (v_uid,
                CASE WHEN abs(extract(epoch FROM (now() - p_provisional_granted_at))) < 86400
                     THEN p_provisional_granted_at ELSE now() END,
                p_provisional_granted_at, 5, 'open');
      END IF;
    END IF;
  END IF;

  INSERT INTO public.payment_events
    (user_id, asaas_payment_id, value_cents, days, status, source)
  VALUES (v_uid, p_asaas_payment_id, p_value_cents, v_days, 'confirmed', p_source)
  RETURNING id INTO v_evt_id;

  -- Desconta graça aberta (30d → 25d).
  SELECT * INTO v_open
  FROM public.trust_graces
  WHERE user_id = v_uid AND status = 'open'
  ORDER BY granted_at DESC
  LIMIT 1;
  v_has_open := FOUND;
  IF v_has_open THEN
    v_deduct := LEAST(v_open.days, v_days - 1);
  END IF;

  SELECT * INTO v_sub
  FROM public.subscriptions
  WHERE user_id = v_uid
  ORDER BY expires_at DESC
  LIMIT 1;
  v_has_sub := FOUND;

  v_base := now();
  IF v_has_sub AND v_sub.expires_at > now() THEN
    v_base := v_sub.expires_at;
  END IF;
  v_new := v_base + ((v_days - v_deduct) || ' days')::interval;
  v_plan := CASE WHEN v_days >= 365
                 THEN 'Standard Anual (Ativo)' ELSE 'Standard (Ativo)' END;

  IF v_has_sub THEN
    UPDATE public.subscriptions
       SET plan_type = 'pix_manual', status = 'active',
           price_cents = p_value_cents, starts_at = now(),
           expires_at = v_new, updated_at = now()
     WHERE id = v_sub.id;
  ELSE
    INSERT INTO public.subscriptions
      (user_id, plan_type, status, price_cents, starts_at, expires_at)
    VALUES (v_uid, 'pix_manual', 'active', p_value_cents, now(), v_new);
  END IF;

  UPDATE public.user_profiles
     SET plan = v_plan, expires_at = v_new, updated_at = now()
   WHERE auth_uid = v_uid;

  IF v_has_open THEN
    UPDATE public.trust_graces
       SET status = 'repaid', repaid_at = now(),
           repaid_payment_event_id = v_evt_id
     WHERE id = v_open.id;
  END IF;

  RETURN jsonb_build_object(
    'applied', true,
    'expires_at', v_new,
    'deducted_days', v_deduct,
    'days', v_days,
    'plan', v_plan,
    'grace_rejected', v_rejected);
END;
$$;

-- ── 7. Trial único por usuário (server-side; acaba trial infinito) ──────────
CREATE OR REPLACE FUNCTION public.fn_start_trial()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_sub RECORD;
  v_prof RECORD;
BEGIN
  IF v_uid IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'no-auth');
  END IF;

  PERFORM set_config('app.money_writer', 'on', true);

  SELECT * INTO v_sub
  FROM public.subscriptions
  WHERE user_id = v_uid
  ORDER BY starts_at DESC
  LIMIT 1;
  IF FOUND THEN
    SELECT * INTO v_prof FROM public.user_profiles WHERE auth_uid = v_uid;
    RETURN jsonb_build_object(
      'ok', true, 'trial', false,
      'expires_at', v_sub.expires_at,
      'plan', COALESCE(v_prof.plan, ''));
  END IF;

  INSERT INTO public.subscriptions
    (user_id, plan_type, status, price_cents, starts_at, expires_at)
  VALUES (v_uid, 'trial', 'trialing', 0, now(), now() + interval '30 days');

  UPDATE public.user_profiles
     SET plan = 'Standard (Trial 30 Dias)',
         expires_at = now() + interval '30 days',
         updated_at = now()
   WHERE auth_uid = v_uid;

  RETURN jsonb_build_object(
    'ok', true, 'trial', true,
    'expires_at', now() + interval '30 days');
END;
$$;

-- Execução das funções pelo app logado.
GRANT EXECUTE ON FUNCTION public.fn_trust_grace_status() TO authenticated;
GRANT EXECUTE ON FUNCTION public.fn_trust_grace_grant(timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fn_apply_payment(text, uuid, int, text, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fn_start_trial() TO authenticated;

-- ── 8. Trava anti-calote: cliente não escreve dinheiro ──────────────────────
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
    -- Cliente: só linha de trial zerada com expiração curta.
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
       AND (NEW.plan NOT ILIKE '%trial%'
            OR NEW.expires_at > now() + interval '31 days') THEN
      RAISE EXCEPTION 'plano inicial inválido'
        USING ERRCODE = '42501';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_subscriptions_guard_money ON public.subscriptions;
CREATE TRIGGER trg_subscriptions_guard_money
  BEFORE INSERT OR UPDATE ON public.subscriptions
  FOR EACH ROW EXECUTE FUNCTION public.trg_guard_money();

DROP TRIGGER IF EXISTS trg_user_profiles_guard_money ON public.user_profiles;
CREATE TRIGGER trg_user_profiles_guard_money
  BEFORE INSERT OR UPDATE ON public.user_profiles
  FOR EACH ROW EXECUTE FUNCTION public.trg_guard_money();

-- ── 9. Conferência ──────────────────────────────────────────────────────────
SELECT 'payment_events' AS tabela, count(*) AS linhas FROM public.payment_events
UNION ALL
SELECT 'trust_graces', count(*) FROM public.trust_graces
UNION ALL
SELECT 'subscriptions', count(*) FROM public.subscriptions;

SELECT proname
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND proname IN ('fn_trust_grace_status', 'fn_trust_grace_grant',
                  'fn_apply_payment', 'fn_start_trial')
ORDER BY 1;
