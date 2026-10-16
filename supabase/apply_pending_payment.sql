-- ============================================================================
-- LIFO — APLICAR PAGAMENTO PENDENTE (pay_qmb5vp4ez61hl5zj)
-- ============================================================================
-- Como o webhook retornou 404 no Hostinger antes da correção, este script
-- executa a função canônica do banco para creditar os +30 dias imediatamente.
--
-- Execução:
--   1. Acesse o Supabase Dashboard:
--      https://supabase.com/dashboard/project/sjbmweuszwxbkdimbwdg/sql
--   2. Cole este comando e clique em RUN.
-- ============================================================================

SELECT public.fn_apply_payment(
  p_asaas_payment_id := 'pay_qmb5vp4ez61hl5zj',
  p_user_id          := '5bf78fbc-5e8c-4b64-975d-081c6dd271b6'::uuid,
  p_value_cents      := 1990,
  p_source           := 'manual_recovery'
);

-- Conferir resultado:
SELECT 
  id, 
  name, 
  email, 
  plan, 
  expires_at, 
  created_at 
FROM public.user_profiles 
WHERE auth_uid = '5bf78fbc-5e8c-4b64-975d-081c6dd271b6';

SELECT 
  id, 
  asaas_payment_id, 
  value_cents, 
  days, 
  status, 
  source, 
  created_at 
FROM public.payment_events 
WHERE asaas_payment_id = 'pay_qmb5vp4ez61hl5zj';
