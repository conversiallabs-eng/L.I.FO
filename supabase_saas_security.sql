-- ============================================================================
-- LIFO SAAS & SECURITY ENGINE - SUPABASE SCHEMA (PRODUCTION READY)
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- 1. TABELA DE PERFIS COM KYC RIGOROSO
CREATE TABLE IF NOT EXISTS public.profiles (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    full_name TEXT NOT NULL CHECK (char_length(trim(full_name)) >= 5),
    cpf VARCHAR(14) NOT NULL,
    cpf_hash TEXT NOT NULL,
    rg VARCHAR(20) NOT NULL,
    phone VARCHAR(20) NOT NULL,
    phone_verified BOOLEAN NOT NULL DEFAULT false,
    cep VARCHAR(9) NOT NULL,
    logradouro TEXT NOT NULL,
    numero TEXT NOT NULL,
    complemento TEXT,
    bairro TEXT NOT NULL,
    cidade TEXT NOT NULL,
    uf VARCHAR(2) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT uq_profiles_cpf_hash UNIQUE (cpf_hash),
    CONSTRAINT uq_profiles_phone UNIQUE (phone)
);

-- 2. DISPOSITIVOS REGISTRADOS (HARDWARE FINGERPRINTING)
CREATE TABLE IF NOT EXISTS public.devices_registered (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    device_fingerprint TEXT NOT NULL,
    platform TEXT NOT NULL CHECK (platform IN ('android', 'ios')),
    device_model TEXT,
    os_version TEXT,
    first_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    is_compromised BOOLEAN NOT NULL DEFAULT false,
    CONSTRAINT uq_user_device UNIQUE (user_id, device_fingerprint)
);

CREATE INDEX IF NOT EXISTS idx_devices_fingerprint ON public.devices_registered(device_fingerprint);

-- 3. AUDITORIA HISTÓRICA DE CONSUMO DE TRIAL (ANTI-RODÍZIO 12 MESES)
CREATE TABLE IF NOT EXISTS public.trial_abuse_audit (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    cpf_hash TEXT NOT NULL,
    device_fingerprint TEXT NOT NULL,
    user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    trial_granted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    trial_expires_at TIMESTAMPTZ NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_trial_cpf_hash ON public.trial_abuse_audit(cpf_hash);
CREATE INDEX IF NOT EXISTS idx_trial_device_fp ON public.trial_abuse_audit(device_fingerprint);

-- 4. TABELA DE ASSINATURAS (PAYWALL / SAAS)
-- Preços: Pix/Boleto: R$ 19,90 (1990 cents) | Cartão Recorrente: R$ 25,00 (2500 cents)
CREATE TABLE IF NOT EXISTS public.subscriptions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    plan_type TEXT NOT NULL CHECK (plan_type IN ('trial', 'pix_manual', 'credit_card_auto')),
    status TEXT NOT NULL CHECK (status IN ('active', 'past_due', 'canceled', 'expired', 'trialing')),
    price_cents INTEGER NOT NULL CHECK (price_cents >= 0),
    starts_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at TIMESTAMPTZ NOT NULL,
    external_provider_id TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_subscriptions_user ON public.subscriptions(user_id, status);

-- 5. CÓDIGOS DE VERIFICAÇÃO OTP (TELEFONE/WHATSAPP)
CREATE TABLE IF NOT EXISTS public.verification_codes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    phone TEXT NOT NULL,
    code_hash TEXT NOT NULL,
    attempts INTEGER NOT NULL DEFAULT 0,
    max_attempts INTEGER NOT NULL DEFAULT 4,
    consumed BOOLEAN NOT NULL DEFAULT false,
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ============================================================================
-- FUNÇÃO ATÔMICA DE CONCESSÃO DE TRIAL (COM CHECAGEM DE 12 MESES)
-- ============================================================================

CREATE OR REPLACE FUNCTION public.fn_claim_30d_trial(
    p_cpf_hash TEXT,
    p_device_fingerprint TEXT,
    p_platform TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_user_id UUID := auth.uid();
    v_has_recent_trial BOOLEAN;
    v_new_sub_id UUID;
    v_expires_at TIMESTAMPTZ := now() + INTERVAL '30 days';
BEGIN
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'Não autenticado.';
    END IF;

    -- Checa se o CPF OU o dispositivo consumiram trial nos últimos 12 meses
    SELECT EXISTS (
        SELECT 1 FROM public.trial_abuse_audit
        WHERE (cpf_hash = p_cpf_hash OR device_fingerprint = p_device_fingerprint)
          AND trial_granted_at > (now() - INTERVAL '365 days')
    ) INTO v_has_recent_trial;

    IF v_has_recent_trial THEN
        RETURN jsonb_build_object(
            'success', false,
            'eligible', false,
            'message', 'Período de teste já utilizado neste dispositivo ou CPF nos últimos 12 meses. Assinatura imediata necessária.'
        );
    END IF;

    -- Registra hardware
    INSERT INTO public.devices_registered (user_id, device_fingerprint, platform, last_seen_at)
    VALUES (v_user_id, p_device_fingerprint, p_platform, now())
    ON CONFLICT (user_id, device_fingerprint)
    DO UPDATE SET last_seen_at = now();

    -- Grava auditoria de Trial
    INSERT INTO public.trial_abuse_audit (cpf_hash, device_fingerprint, user_id, trial_expires_at)
    VALUES (p_cpf_hash, p_device_fingerprint, v_user_id, v_expires_at);

    -- Cria assinatura Trial de 30 dias
    INSERT INTO public.subscriptions (user_id, plan_type, status, price_cents, starts_at, expires_at)
    VALUES (v_user_id, 'trial', 'trialing', 0, now(), v_expires_at)
    RETURNING id INTO v_new_sub_id;

    RETURN jsonb_build_object(
        'success', true,
        'eligible', true,
        'subscription_id', v_new_sub_id,
        'expires_at', v_expires_at
    );
END;
$$;

-- ============================================================================
-- ROW LEVEL SECURITY (RLS) POLICIES
-- ============================================================================

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.devices_registered ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.trial_abuse_audit ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.verification_codes ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own profile"
    ON public.profiles FOR SELECT
    USING (auth.uid() = id);

CREATE POLICY "Users can insert own profile"
    ON public.profiles FOR INSERT
    WITH CHECK (auth.uid() = id);

CREATE POLICY "Users can update own profile"
    ON public.profiles FOR UPDATE
    USING (auth.uid() = id);

CREATE POLICY "Users can view own devices"
    ON public.devices_registered FOR SELECT
    USING (auth.uid() = user_id);

CREATE POLICY "Users can register own devices"
    ON public.devices_registered FOR INSERT
    WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can view own subscriptions"
    ON public.subscriptions FOR SELECT
    USING (auth.uid() = user_id);

CREATE POLICY "No public access to trial audit"
    ON public.trial_abuse_audit FOR ALL
    USING (false);

CREATE POLICY "No public direct access to verification codes"
    ON public.verification_codes FOR ALL
    USING (false);
