-- ============================================================================
-- L.I.F.O — PUBLICAR VERSÃO NOVA DO APK (v1.0.4+10)
-- ============================================================================
--
-- COMO USAR:
--   1. Dashboard do Supabase → SQL Editor → cole este arquivo completo.
--   2. Clique em RUN.
--
-- ============================================================================

-- 1. Tabela e permissões RLS (anon e authenticated podem ler versão e chaves de mapa)
CREATE TABLE IF NOT EXISTS public.app_config (
  key         TEXT PRIMARY KEY,
  value       TEXT NOT NULL DEFAULT '',
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.app_config ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Anon can read release keys" ON public.app_config;
DROP POLICY IF EXISTS "Anon can read public map keys" ON public.app_config;
DROP POLICY IF EXISTS "Anon can read app_config" ON public.app_config;

CREATE POLICY "Anon can read app_config"
  ON public.app_config FOR SELECT
  TO anon
  USING (key IN ('latest_version', 'latest_build', 'apk_url', 'release_notes', 'mapbox_token', 'carto_key'));

DROP POLICY IF EXISTS "Authenticated can read app_config" ON public.app_config;
CREATE POLICY "Authenticated can read app_config"
  ON public.app_config FOR SELECT
  TO authenticated
  USING (true);

-- 2. Registrar versão publicada (v1.0.4 build 18) e Token Mapbox para Satélite
INSERT INTO public.app_config (key, value, updated_at)
VALUES
  ('latest_version', '1.0.4',                                        now()),
  ('latest_build',   '18',                                           now()),
  ('apk_url',        'https://lifo.com.br/lifo.apk',                  now()),
  ('release_notes',  '1. Mapa Ultralimpo sem Obstruções: remoção total de paradas de ônibus e pontos de interesse poluentes, mantendo 100% das ruas e nomes em alta nitidez.' || E'\n' ||
                     '2. Scanner Compacto em Janela: bipe pacotes e etiquetas diretamente da tela do mapa com apenas 1 toque.' || E'\n' ||
                     '3. Busca Direta de Pacote: achou pacote misturado? É só bipar e o L.I.F.O localiza o cliente e traça a rota na hora.' || E'\n' ||
                     '4. Toque Longo para Editar Endereço: pressione e segure qualquer parada da lista para corrigir endereço e reotimizar instantaneamente.' || E'\n' ||
                     '5. Visual Profissional de Alta Precisão: cartões e alertas em cores sólidas de alto contraste, sem tons pastéis.' || E'\n' ||
                     '6. Marcador Real de Entregas: contador exato de pacotes finalizados para você acompanhar seu progresso no corre.', now()),
  ('mapbox_token',   convert_from(decode('cGsuZXlKMUlqb2libUZ1YjI1aGJtODJNVE1pTENKaElqb2lZMjEyT0dSM2EyazVNSE50YVRKNWJ6ZDVlVEprYTNNNFlpSjkuSVBNdWQwLVJiSkpDWjdQQVhCaUNQdw==', 'base64'), 'UTF-8'), now())
ON CONFLICT (key) DO UPDATE
  SET value = EXCLUDED.value, updated_at = now();

-- 3. Conferência final (retorna as chaves atualizadas com a confirmação)
SELECT key, value, updated_at
FROM public.app_config
WHERE key IN ('latest_version', 'latest_build', 'apk_url', 'release_notes', 'mapbox_token')
ORDER BY key;
