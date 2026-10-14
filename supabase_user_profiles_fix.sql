-- ============================================================================
-- L.I.F.O — FIX: perfil do usuário persiste de verdade (CPF/RG/fone/endereço)
-- ============================================================================
-- POR QUE os dados "não ficavam salvos":
--   1. O app grava em public.user_profiles via UPSERT com onConflict=auth_uid.
--      Se a tabela não tem todas as colunas (cpf, rg, phone, billing_* ...),
--      o upsert falha e NADA é gravado.
--   2. Sem policy de UPDATE (ou sem UNIQUE em auth_uid), a 1ª gravação
--      (INSERT) passa mas toda EDIÇÃO seguinte é recusada pelo RLS.
--   3. O app engolia o erro e mostrava "sucesso" — no restart, o fetch
--      trazia os dados velhos e parecia que "sumiu".
--
-- COMO RODAR (2 min, sem CLI/Docker):
--   1. Abra https://supabase.com/dashboard/project/sjbmweuszwxbkdimbwdg/sql
--   2. Cole este arquivo inteiro no editor e clique em RUN.
--   3. Verifique o resultado das consultas de conferência no final.
-- É 100% idempotente: pode rodar quantas vezes quiser.
-- ============================================================================

-- 1. Garante a tabela com TODAS as colunas que o app envia -------------------
CREATE TABLE IF NOT EXISTS public.user_profiles (
  id              TEXT PRIMARY KEY,
  auth_uid        UUID NOT NULL,
  name            TEXT NOT NULL DEFAULT '',
  email           TEXT NOT NULL DEFAULT '',
  cpf             TEXT,
  rg              TEXT,
  phone           TEXT,
  billing_address TEXT,
  billing_cep     TEXT,
  city_uf         TEXT,
  vehicle_type    TEXT,
  avatar_url      TEXT,
  plan            TEXT NOT NULL DEFAULT 'Standard (Trial 30 Dias)',
  expires_at      TIMESTAMPTZ NOT NULL DEFAULT (now() + INTERVAL '30 days'),
  fcm_token       TEXT,
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Colunas que podem faltar se a tabela foi criada antiga (um por um, seguro):
ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS auth_uid UUID;
ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS name TEXT NOT NULL DEFAULT '';
ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS email TEXT NOT NULL DEFAULT '';
ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS cpf TEXT;
ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS rg TEXT;
ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS phone TEXT;
ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS billing_address TEXT;
ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS billing_cep TEXT;
ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS city_uf TEXT;
ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS vehicle_type TEXT;
ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS avatar_url TEXT;
ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS plan TEXT NOT NULL DEFAULT 'Standard (Trial 30 Dias)';
ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS expires_at TIMESTAMPTZ NOT NULL DEFAULT (now() + INTERVAL '30 days');
ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS fcm_token TEXT;
ALTER TABLE public.user_profiles ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT now();

-- 2. auth_uid único: o upsert do app usa onConflict=auth_uid ------------------
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'uq_user_profiles_auth_uid'
  ) THEN
    ALTER TABLE public.user_profiles
      ADD CONSTRAINT uq_user_profiles_auth_uid UNIQUE (auth_uid);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_user_profiles_auth_uid
  ON public.user_profiles (auth_uid);

-- 3. RLS: o dono lê, cria e EDITA o próprio perfil -----------------------------
ALTER TABLE public.user_profiles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view own user_profile" ON public.user_profiles;
CREATE POLICY "Users can view own user_profile"
  ON public.user_profiles FOR SELECT
  USING (auth.uid() = auth_uid);

DROP POLICY IF EXISTS "Users can insert own user_profile" ON public.user_profiles;
CREATE POLICY "Users can insert own user_profile"
  ON public.user_profiles FOR INSERT
  WITH CHECK (auth.uid() = auth_uid);

-- ESTA é a que faltava e impedia as edições (HTTP 400/403 silencioso no app):
DROP POLICY IF EXISTS "Users can update own user_profile" ON public.user_profiles;
CREATE POLICY "Users can update own user_profile"
  ON public.user_profiles FOR UPDATE
  USING (auth.uid() = auth_uid)
  WITH CHECK (auth.uid() = auth_uid);

-- 4. Assinaturas: garante leitura/escrita própria (renovação persiste) ----------
CREATE TABLE IF NOT EXISTS public.subscriptions (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID NOT NULL,
  plan_type   TEXT NOT NULL DEFAULT 'trial',
  status      TEXT NOT NULL DEFAULT 'trialing',
  price_cents INTEGER NOT NULL DEFAULT 0,
  starts_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at  TIMESTAMPTZ NOT NULL,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.subscriptions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view own subscriptions" ON public.subscriptions;
CREATE POLICY "Users can view own subscriptions"
  ON public.subscriptions FOR SELECT
  USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can insert own subscriptions" ON public.subscriptions;
CREATE POLICY "Users can insert own subscriptions"
  ON public.subscriptions FOR INSERT
  WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can update own subscriptions" ON public.subscriptions;
CREATE POLICY "Users can update own subscriptions"
  ON public.subscriptions FOR UPDATE
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

-- 5. CONFERÊNCIA — o resultado aparece na aba Results após o RUN ---------------
-- 5a. Colunas da tabela (tem que listar: cpf, rg, phone, billing_address...):
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'user_profiles'
ORDER BY ordinal_position;

-- 5b. Policies ativas (tem que ter SELECT + INSERT + UPDATE):
SELECT policyname, cmd
FROM pg_policies
WHERE schemaname = 'public' AND tablename = 'user_profiles'
ORDER BY cmd;
