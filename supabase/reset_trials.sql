-- ============================================================================
-- L.I.F.O — RESET TOTAL DE TESTES GRÁTIS (AUDITORIA, ASSINATURAS E PERFIS)
-- ============================================================================
-- Use este script para zerar todos os testes grátis:
--   1. Limpa toda a auditoria de CPFs e Aparelhos físicos (trial_abuse_audit).
--   2. Remove todas as assinaturas 'trial' (subscriptions).
--   3. Reseta os perfis para 'Pendente de Ativação' com 0 dias (user_profiles).
-- Todos os CPFs e celulares voltam a ter direito a 30 dias de teste do zero!
-- ============================================================================

BEGIN;

-- Habilita permissão administrativa para atualizar campos protegidos
SET LOCAL app.money_writer = 'on';

-- 1. Limpa todo o histórico de auditoria anti-abuso
TRUNCATE TABLE public.trial_abuse_audit RESTART IDENTITY;

-- 2. Remove assinaturas do tipo trial
DELETE FROM public.subscriptions WHERE plan_type = 'trial';

-- 3. Reseta todos os perfis para Pendente de Ativação
UPDATE public.user_profiles
   SET plan = 'Pendente de Ativação',
       expires_at = now(),
       updated_at = now();

COMMIT;

-- 4. Verificação final
SELECT 'trial_abuse_audit' AS tabela, count(*) AS total FROM public.trial_abuse_audit
UNION ALL
SELECT 'subscriptions_trial', count(*) FROM public.subscriptions WHERE plan_type = 'trial'
UNION ALL
SELECT 'user_profiles_pendentes', count(*) FROM public.user_profiles WHERE plan = 'Pendente de Ativação';
