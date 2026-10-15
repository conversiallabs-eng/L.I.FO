-- ============================================================================
-- L.I.F.O — app_config: chaves e parametros lidos pelo app em runtime
-- ============================================================================
-- POR QUE: chaves (ex.: CARTO Basemaps) NÃO vão hardcoded no APK — um
-- descompilador leria na hora. Ficam aqui, com RLS de leitura p/ logados,
-- e o app guarda em cache local após o 1º boot online.
--
-- COMO APLICAR:
--   A) CLI:  supabase db push --linked
--   B) Dashboard: SQL editor → colar → RUN (idempotente).
-- A LINHA DA KEY NÃO VAI NESTE ARQUIVO (não commitar segredo): rode no
-- dashboard, uma vez, o INSERT do passo 3 com a key da CARTO.
-- ============================================================================

-- 1. Tabela chave → valor -----------------------------------------------------
CREATE TABLE IF NOT EXISTS public.app_config (
  key         TEXT PRIMARY KEY,
  value       TEXT NOT NULL DEFAULT '',
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.app_config ENABLE ROW LEVEL SECURITY;

-- Leitura: qualquer usuário logado. Escrita: NINGUÉM via API
-- (só service_role/dashboard). Sem INSERT/UPDATE/DELETE p/ authenticated:
-- se o app precisar gravar config um dia, faz via função SECURITY DEFINER.
DROP POLICY IF EXISTS "Authenticated can read app_config" ON public.app_config;
CREATE POLICY "Authenticated can read app_config"
  ON public.app_config FOR SELECT
  TO authenticated
  USING (true);

-- 2. Chaves conhecidas (linhas criadas vazias; o VALOR real entra pelo
--    dashboard — ver passo 3. Linha vazia = app usa fallback Mapbox).
INSERT INTO public.app_config (key, value)
VALUES ('carto_key', '')
ON CONFLICT (key) DO NOTHING;

-- 3. >>> RODAR NO DASHBOARD (SQL editor), UMA VEZ, COM A KEY REAL: <<<
--    UPDATE public.app_config SET value = 'COLE_A_KEY_CARTO_AQUI',
--      updated_at = now() WHERE key = 'carto_key';
--    (service_role/dashboard bypassa RLS; oGRANT de escrita p/ authenticated
--    propositalmente não existe.)

-- 4. Conferência ---------------------------------------------------------------
SELECT key, (value <> '') AS tem_valor, updated_at
FROM public.app_config
ORDER BY key;
