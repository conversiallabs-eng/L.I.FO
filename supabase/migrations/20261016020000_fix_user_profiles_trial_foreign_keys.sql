-- ============================================================================
-- Fix user_profiles expires_at default & subscriptions foreign key constraint
-- ============================================================================

-- 1. Garante que expires_at nunca falhe por NOT NULL sem default no insert/upsert
ALTER TABLE public.user_profiles ALTER COLUMN expires_at SET DEFAULT (now() + interval '30 days');
ALTER TABLE public.user_profiles ALTER COLUMN expires_at DROP NOT NULL;

-- 2. Corrige FK de subscriptions para apontar para auth.users(id) em vez de tabela legada
ALTER TABLE public.subscriptions DROP CONSTRAINT IF EXISTS subscriptions_user_id_fkey;
ALTER TABLE public.subscriptions 
  ADD CONSTRAINT subscriptions_user_id_fkey 
  FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;

-- 3. Remove sobrecarga antiga de fn_start_trial sem parâmetros
DROP FUNCTION IF EXISTS public.fn_start_trial();

-- 4. Recarrega cache do PostgREST
NOTIFY pgrst, 'reload schema';
