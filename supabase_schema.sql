-- Supabase Schema para o Projeto L.I.F.O
-- Projeto ID: sjbmweuszwxbkdimbwdg
-- URL: https://sjbmweuszwxbkdimbwdg.supabase.co

-- 1. Tabela de Versoes Imutaveis de Manifesto
CREATE TABLE IF NOT EXISTS manifest_versions (
  id UUID PRIMARY KEY,
  version_index INTEGER NOT NULL,
  label TEXT NOT NULL,
  parent_version_id UUID REFERENCES manifest_versions(id) ON DELETE SET NULL,
  raw_data JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  is_current BOOLEAN NOT NULL DEFAULT FALSE,
  total_stops INTEGER NOT NULL DEFAULT 0,
  total_packages INTEGER NOT NULL DEFAULT 0
);

-- 2. Tabela de Paradas de Entrega
CREATE TABLE IF NOT EXISTS delivery_stops (
  id UUID PRIMARY KEY,
  manifest_version_id UUID NOT NULL REFERENCES manifest_versions(id) ON DELETE CASCADE,
  sequence_index INTEGER NOT NULL,
  recipient_name TEXT NOT NULL,
  address TEXT NOT NULL,
  latitude DOUBLE PRECISION NOT NULL,
  longitude DOUBLE PRECISION NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',
  spatial_slot TEXT NOT NULL,
  time_window TEXT,
  notes TEXT
);

-- 3. Tabela de Itens de Pacotes
CREATE TABLE IF NOT EXISTS package_items (
  id UUID PRIMARY KEY,
  manifest_version_id UUID NOT NULL REFERENCES manifest_versions(id) ON DELETE CASCADE,
  stop_id UUID NOT NULL REFERENCES delivery_stops(id) ON DELETE CASCADE,
  barcode TEXT NOT NULL,
  description TEXT NOT NULL,
  weight_kg DOUBLE PRECISION NOT NULL,
  volume_m3 DOUBLE PRECISION NOT NULL DEFAULT 0.05,
  spatial_slot TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pendingLoad',
  scanned_at TIMESTAMPTZ
);

-- Indices para performance de busca instantanea
CREATE INDEX IF NOT EXISTS idx_supabase_packages_barcode ON package_items(barcode);
CREATE INDEX IF NOT EXISTS idx_supabase_stops_manifest ON delivery_stops(manifest_version_id);
CREATE INDEX IF NOT EXISTS idx_supabase_manifest_version ON manifest_versions(version_index DESC);

-- 4. Fila de Sincronizacao em Segundo Plano
CREATE TABLE IF NOT EXISTS sync_queue (
  id UUID PRIMARY KEY,
  entity_type TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  action TEXT NOT NULL,
  payload JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  synced BOOLEAN NOT NULL DEFAULT FALSE
);
