-- L.I.F.O — app_config: leitura anon das chaves públicas de mapa
-- POR QUE: o boot busca carto_key/mapbox_token ANTES do login (anon).
-- Com RLS só-authenticated, fresh install caía no fallback Mapbox.
-- As 2 chaves já são públicas por natureza (CARTO irrestrita + pk. Mapbox),
-- então liberar SELECT anon só delas não expõe nada novo.
-- Idempotente.
DROP POLICY IF EXISTS "Anon can read public map keys" ON public.app_config;
CREATE POLICY "Anon can read public map keys"
  ON public.app_config FOR SELECT
  TO anon
  USING (key IN ('carto_key', 'mapbox_token'));
