-- ============================================================================
-- L.I.F.O — Correção: a confiança (+5 dias) precisa VALER no servidor
-- ============================================================================
-- BUG: fn_trust_grace_grant só gravava a graça no ledger (trust_graces) e NÃO
-- estendia subscriptions/user_profiles.expires_at. O app mostrava +5 dias só
-- localmente; no próximo boot/login/revalidação lia a expiração antiga
-- (vencida) do servidor, via graça "aberta" e exibia "Você usou os 5 dias de
-- confiança" no MESMO dia.
--
-- CORREÇÃO (justa — ninguém perde dia de trial nem de assinatura):
--   1. Conceder a graça agora estende a expiração oficial até granted_at+5d
--      (só estende, nunca encurta).
--   2. fn_apply_payment parte de MAX(agora, expiração, fim da graça aberta):
--        • pagou DENTRO dos 5 dias:  fim_da_graça + 25d  (= 30d contados do
--          vencimento original; nenhum dia de graça se perde);
--        • pagou DEPOIS da graça:    agora + 25d (5 dias já foram usados);
--        • sem graça aberta:         soma cheia (30d/365d) sobre o que resta
--          (trial/assinatura vigente NUNCA é descontado).
--   3. Reparo dos dados: graças abertas existentes têm a expiração estendida.
-- Idempotente: pode rodar quantas vezes quiser.
-- ============================================================================

-- ── 1. Helper interno: só estende, nunca encurta (sem acesso de cliente) ────
CREATE OR REPLACE FUNCTION public.fn_extend_expiry(
  p_uid   uuid,
  p_until timestamptz
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF p_uid IS NULL OR p_until IS NULL THEN
    RETURN;
  END IF;

  PERFORM set_config('app.money_writer', 'on', true);

  UPDATE public.subscriptions
     SET expires_at = p_until, updated_at = now()
   WHERE id = (
           SELECT id FROM public.subscriptions
            WHERE user_id = p_uid
            ORDER BY expires_at DESC
            LIMIT 1
         )
     AND expires_at < p_until;

  UPDATE public.user_profiles
     SET expires_at = p_until, updated_at = now()
   WHERE auth_uid = p_uid
     AND (expires_at IS NULL OR expires_at < p_until);
END;
$$;

REVOKE ALL ON FUNCTION public.fn_extend_expiry(uuid, timestamptz)
  FROM PUBLIC, anon, authenticated;

-- ── 2. Concessão: registra no ledger E estende a expiração oficial ──────────
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
  v_end   timestamptz;
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
    -- Já há adiantamento aberto: não duplica; garante que a expiração
    -- oficial reflita a graça (cura casos anteriores a esta correção).
    v_end := v_open.granted_at + (v_open.days || ' days')::interval;
    PERFORM public.fn_extend_expiry(v_uid, v_end);
    RETURN jsonb_build_object(
      'ok', true, 'already', true,
      'granted_at', v_open.granted_at,
      'days', v_open.days,
      'expires_at', v_end);
  END IF;

  -- Hora efetiva: alegação do aparelho se plausível (±24h), senão agora.
  v_eff := now();
  IF p_device_granted_at IS NOT NULL
     AND abs(extract(epoch FROM (now() - p_device_granted_at))) < 86400 THEN
    v_eff := p_device_granted_at;
  END IF;
  v_end := v_eff + (v_days || ' days')::interval;

  INSERT INTO public.trust_graces (user_id, granted_at, device_granted_at, days, status)
  VALUES (v_uid, v_eff, p_device_granted_at, v_days, 'open');

  -- A graça passa a valer no servidor (boot/login/revalidação leem isto).
  PERFORM public.fn_extend_expiry(v_uid, v_end);

  RETURN jsonb_build_object(
    'ok', true, 'already', false,
    'granted_at', v_eff,
    'days', v_days,
    'expires_at', v_end);
END;
$$;

-- ── 3. Aplicação de pagamento justa (escritor único, idempotente) ───────────
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
  v_uid       uuid := COALESCE(p_user_id, auth.uid());
  v_days      int;
  v_evt_id    uuid;
  v_open      RECORD;
  v_has_open  boolean := false;
  v_grace_end timestamptz;
  v_deduct    int := 0;
  v_sub       RECORD;
  v_has_sub   boolean := false;
  v_base      timestamptz;
  v_new       timestamptz;
  v_plan      text;
  v_rejected  boolean := false;
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
      -- A regra exige ter pago ANTES. Rejeita a provisória.
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

  -- Graça aberta: os dias adiantados já foram usados (ou estão no prazo).
  SELECT * INTO v_open
  FROM public.trust_graces
  WHERE user_id = v_uid AND status = 'open'
  ORDER BY granted_at DESC
  LIMIT 1;
  v_has_open := FOUND;
  IF v_has_open THEN
    v_deduct := LEAST(v_open.days, v_days - 1);
    v_grace_end := v_open.granted_at + (v_open.days || ' days')::interval;
  END IF;

  SELECT * INTO v_sub
  FROM public.subscriptions
  WHERE user_id = v_uid
  ORDER BY expires_at DESC
  LIMIT 1;
  v_has_sub := FOUND;

  -- Base justa: o MAIOR entre agora, a validade vigente e o fim da graça.
  -- Pagou dentro dos 5 dias → nenhum dia de graça se perde.
  v_base := now();
  IF v_has_sub AND v_sub.expires_at > v_base THEN
    v_base := v_sub.expires_at;
  END IF;
  IF v_has_open AND v_grace_end > v_base THEN
    v_base := v_grace_end;
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

GRANT EXECUTE ON FUNCTION public.fn_trust_grace_grant(timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.fn_apply_payment(text, uuid, int, text, timestamptz) TO authenticated;

-- ── 4. Reparo: graças já abertas passam a valer no servidor ─────────────────
DO $$
DECLARE
  g RECORD;
BEGIN
  FOR g IN
    SELECT user_id, max(granted_at + (days || ' days')::interval) AS until
    FROM public.trust_graces
    WHERE status = 'open'
    GROUP BY user_id
  LOOP
    PERFORM public.fn_extend_expiry(g.user_id, g.until);
  END LOOP;
END;
$$;

-- ── 5. Conferência: graças abertas x expiração oficial ──────────────────────
SELECT g.user_id,
       g.granted_at,
       g.granted_at + (g.days || ' days')::interval AS fim_da_graca,
       p.expires_at AS perfil_expira,
       s.expires_at AS assinatura_expira
FROM public.trust_graces g
LEFT JOIN public.user_profiles p ON p.auth_uid = g.user_id
LEFT JOIN public.subscriptions s ON s.user_id = g.user_id
WHERE g.status = 'open';
