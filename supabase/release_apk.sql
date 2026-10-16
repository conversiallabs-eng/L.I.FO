-- ============================================================================
-- L.I.F.O — PUBLICAR UMA VERSÃO NOVA DO APK
-- ============================================================================
--
-- COMO USAR:
--   1. Dashboard do Supabase → SQL Editor → cole este arquivo completo.
--   2. Clique em RUN.
--
-- ============================================================================

-- 1. Tabela e permissão de leitura anônima para as chaves de release
CREATE TABLE IF NOT EXISTS public.app_config (
  key         TEXT PRIMARY KEY,
  value       TEXT NOT NULL DEFAULT '',
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.app_config ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Anon can read release keys" ON public.app_config;
CREATE POLICY "Anon can read release keys"
  ON public.app_config FOR SELECT
  TO anon
  USING (key IN ('latest_version', 'latest_build', 'apk_url', 'release_notes'));

-- 2. Registrar versão publicada (v1.0.3 build 4)
INSERT INTO public.app_config (key, value, updated_at)
VALUES
  ('latest_version', '1.0.3',                                        now()),
  ('latest_build',   '4',                                            now()),
  ('apk_url',        'https://lifo.com.br/lifo.apk',                  now()),
  ('release_notes',  'Blindagem de segurança anti-rodízio de contas, validação única de hardware e melhorias de estabilidade.', now())
ON CONFLICT (key) DO UPDATE
  SET value = EXCLUDED.value, updated_at = now();

-- 3. Conferência final (retorna as 4 chaves atualizadas)
SELECT key, value, updated_at
FROM public.app_config
WHERE key IN ('latest_version', 'latest_build', 'apk_url', 'release_notes')
ORDER BY key;
