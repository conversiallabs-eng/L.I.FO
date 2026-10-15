-- ============================================================================
-- L.I.F.O — token Mapbox também via servidor (rotação sem update do app)
-- ============================================================================
-- O pk. Mapbox já é público por natureza (embarcado no app desde o dia 1),
-- então semear o valor aqui não expõe nada novo. A partir daqui, a verdade
-- é a linha abaixo: para ROTACIONAR, basta UPDATE no dashboard (SQL editor
-- ou Table Editor) — o app repuxa no próximo boot online.
-- Leitura: mesmos RLS do app_config (só authenticated lê, ninguém escreve).
-- Idempotente.
-- ============================================================================

INSERT INTO public.app_config (key, value)
VALUES (
  'mapbox_token',
  ''
)
ON CONFLICT (key) DO NOTHING;

SELECT key, (value <> '') AS tem_valor, updated_at
FROM public.app_config
ORDER BY key;
