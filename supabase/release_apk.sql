-- ============================================================================
-- L.I.F.O — PUBLICAR UMA VERSÃO NOVA DO APK (rodar a CADA release)
-- ============================================================================
-- PARA QUE SERVE
--   O app lê estas 4 linhas do `app_config` no boot e compara com a versão
--   instalada (PackageInfo). Se a publicada aqui for DIFERENTE da instalada
--   (nome de versão ou build), aparece a bolhinha "1" no botão de menu e o
--   botão "Atualizar para X" no drawer ("Verificar atualizações").
--   Só quando o nome E o build forem os mesmos da instalada é que nada
--   acontece — é a única coisa que não vale a pena baixar de novo.
--
-- COMO USAR (4 passos por release)
--   1. Suba o APK novo para a Hostinger no mesmo caminho (ex.: lifo.apk).
--   2. No pubspec.yaml, suba a versão:  version: 1.0.1+2   (nome + build).
--      O `+2` é o versionCode — é ele que diferencia um rebuild com o MESMO
--      nome de versão. NUNCA repita nome+build de um APK já publicado:
--      é essa combinação que o app usa para dizer "já está instalado".
--   3. Edite as 4 variáveis do bloco PASSO 2 abaixo com os valores deste
--      release.
--   4. Dashboard do Supabase → SQL Editor → cole este arquivo → RUN.
--      (Idempotente: rodar de novo só reescreve as mesmas linhas.)
--
-- OBS.: `apk_url` é configurável de propósito — se um dia o APK mudar de
-- host ou de nome, muda aqui sem precisar de um update no APK antigo.
-- ============================================================================

-- PASSO 1. Tabela e leitura anon das chaves de release ------------------------
-- (Normalmente já criada pela migration 20261015010000_app_config.sql; o
-- CREATE abaixo só garante que este script roda sozinho num projeto novo.)
CREATE TABLE IF NOT EXISTS public.app_config (
  key         TEXT PRIMARY KEY,
  value       TEXT NOT NULL DEFAULT '',
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.app_config ENABLE ROW LEVEL SECURITY;

-- A checagem roda no boot, antes de existir sessão: com RLS só-authenticated
-- a bolhinha nunca apareceria. Nada aqui é segredo (versão + URL pública do
-- APK, que o site já expõe), então liberar SELECT anon só destas 4 chaves
-- não expõe nada novo. Idempotente.
DROP POLICY IF EXISTS "Anon can read release keys" ON public.app_config;
CREATE POLICY "Anon can read release keys"
  ON public.app_config FOR SELECT
  TO anon
  USING (key IN ('latest_version', 'latest_build', 'apk_url', 'release_notes'));

-- PASSO 2. Versão publicada --------------------------------------------------
-- ATENÇÃO: os valores abaixo são os do release JÁ publicado. Trocar TODOS
-- pelos do APK novo antes de rodar — rodar com os antigos é inofensivo (não
-- oferece update errado), mas também não avisa ninguém.
-- ┌───────────────────── EDITE SÓ AS 4 VARIÁVEIS ─────────────────────────┐
DO $$
DECLARE
  v_version TEXT    := '1.0.1';                          -- versionName do APK
  v_build   INTEGER := 2;                                -- versionCode (+N)
  v_apk_url TEXT    := 'https://lifo.com.br/lifo.apk';   -- URL na Hostinger
  v_notes   TEXT    := 'Melhorias de desempenho e correções de estabilidade.';
  v_current TEXT;
BEGIN
-- └───────────────────────────────────────────────────────────────────────┘

  IF v_version = '' OR v_apk_url = '' THEN
    RAISE EXCEPTION 'release_apk: preencha v_version e v_apk_url antes de rodar';
  END IF;

  -- Avisa (não falha) quando o nome do release não mudou: quem já está
  -- nessa versão não verá a bolhinha (só o build novo a liga).
  SELECT value INTO v_current FROM public.app_config WHERE key = 'latest_version';
  IF v_current = v_version THEN
    RAISE NOTICE 'atenção: % já era o release publicado — ajuste v_version/v_build do APK novo', v_version;
  END IF;

  INSERT INTO public.app_config (key, value, updated_at)
  VALUES
    ('latest_version', v_version,     now()),
    ('latest_build',   v_build::text, now()),
    ('apk_url',        v_apk_url,     now()),
    ('release_notes',  v_notes,       now())
  ON CONFLICT (key) DO UPDATE
    SET value = EXCLUDED.value, updated_at = now();

  RAISE NOTICE 'release publicado: % (+%) em %', v_version, v_build, v_apk_url;
END $$;

-- PASSO 3. Conferência -------------------------------------------------------
-- Se `latest_version`/`latest_build` forem maiores que a versão instalada
-- (o `version:` do pubspec do APK no ar), os aparelhos com o APK antigo vão
-- mostrar a bolhinha.
SELECT key, value, updated_at
FROM public.app_config
WHERE key IN ('latest_version', 'latest_build', 'apk_url', 'release_notes')
ORDER BY key;
