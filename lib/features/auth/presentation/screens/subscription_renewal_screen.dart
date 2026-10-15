import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../controllers/auth_controller.dart';
import '../../data/services/asaas_payment_service.dart';
import '../../domain/models/subscription_plan.dart';
import 'my_account_screen.dart';
import 'pix_payment_screen.dart';

class SubscriptionRenewalScreen extends ConsumerStatefulWidget {
  /// locked: sem voltar (expirado travado no PIX). O botão de confiança
  /// aparece dentro só para quem pode tomar (servidor decide online).
  final bool locked;

  const SubscriptionRenewalScreen({super.key, this.locked = false});

  static Future<void> open(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const SubscriptionRenewalScreen(),
        fullscreenDialog: true,
      ),
    );
  }

  static Future<void> openLocked(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const SubscriptionRenewalScreen(locked: true),
        fullscreenDialog: true,
      ),
    );
  }

  @override
  ConsumerState<SubscriptionRenewalScreen> createState() =>
      _SubscriptionRenewalScreenState();
}

class _SubscriptionRenewalScreenState
    extends ConsumerState<SubscriptionRenewalScreen> {
  bool _isLoadingPix = false;
  AsaasPixChargeResponse? _pixResponse;
  String _selectedPlanId = SubscriptionPlan.monthly.id;
  SubscriptionPlan _lastChargedPlan = SubscriptionPlan.monthly;
  bool? _canGrace;
  bool _gracePending = false;
  bool _grantingGrace = false;

  @override
  void initState() {
    super.initState();
    _loadGraceInfo();
  }

  Future<void> _loadGraceInfo() async {
    try {
      final ctrl = ref.read(authControllerProvider.notifier);
      final can = await ctrl.canTakeGrace();
      final pending = await ctrl.isGracePending();
      if (!mounted) return;
      setState(() {
        _canGrace = can;
        _gracePending = pending;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _canGrace = false);
    }
  }

  Future<void> _takeGrace() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Liberar na confiança?'),
        content: const Text(
          'O LIFO libera seu app por mais 5 dias na confiança. '
          'Quando você pagar, a renovação libera 25 dias '
          '(5 já usados na confiança).',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Agora não'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Liberar 5 dias'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    setState(() => _grantingGrace = true);
    HapticFeedback.mediumImpact();
    final ok =
        await ref.read(authControllerProvider.notifier).grantTrustGrace();
    if (!mounted) return;
    setState(() => _grantingGrace = false);
    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Liberado por 5 dias na confiança! Bom trabalho.'),
          backgroundColor: Color(0xFF059669),
        ),
      );
      Navigator.of(context).pop();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Não foi possível liberar agora. Tente o PIX.'),
          backgroundColor: Color(0xFFDC2626),
        ),
      );
      await _loadGraceInfo();
    }
  }

  SubscriptionPlan get _selectedPlan => SubscriptionPlan.byId(_selectedPlanId);

  String _formatExpiryDate(DateTime dt) {
    final day = dt.day.toString().padLeft(2, '0');
    final month = dt.month.toString().padLeft(2, '0');
    final year = dt.year;
    return '$day/$month/$year';
  }

  int _daysRemaining(DateTime dt) {
    final diff = dt.difference(DateTime.now()).inDays;
    return diff < 0 ? 0 : diff;
  }

  /// Gera o PIX e abre o takeover animado. A ativação é automática
  /// (polling no app + webhook no servidor) — sem botão manual.
  Future<void> _generatePixCharge() async {
    setState(() {
      _isLoadingPix = true;
    });
    HapticFeedback.mediumImpact();

    final user = ref.read(authControllerProvider).user;
    try {
      final plan = _selectedPlan;
      final pix = await AsaasPaymentService.instance.createPixCharge(
        user: user,
        amount: plan.amount,
        description: plan.description,
      );

      if (!mounted) return;
      setState(() {
        _pixResponse = pix;
        _lastChargedPlan = plan;
        _isLoadingPix = false;
      });
      HapticFeedback.lightImpact();
      final paid = await PixPaymentScreen.open(context, pix, plan: plan);
      // Pagou lá dentro: a assinatura já foi renovada — volta sozinho.
      if (paid && mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingPix = false;
        });
        final msg = e.toString().replaceFirst('Exception: ', '');
        final isCpfError = msg.toLowerCase().contains('cpf');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.error_outline,
                    color: Colors.white, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    msg,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                ),
              ],
            ),
            backgroundColor: const Color(0xFFDC2626),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10)),
            duration: const Duration(seconds: 6),
            action: isCpfError
                ? SnackBarAction(
                    label: 'CORRIGIR',
                    textColor: Colors.white,
                    onPressed: () => MyAccountScreen.open(context),
                  )
                : null,
          ),
        );
      }
    }
  }

  String _maskCpf(String? cpf) {
    final d = (cpf ?? '').replaceAll(RegExp(r'\D'), '');
    if (d.isEmpty) return 'não cadastrado';
    if (d.length != 11) return '*** (incompleto)';
    return '***.***.${d.substring(6, 9)}-${d.substring(9)}';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final user = ref.watch(authControllerProvider).user;

    final bg = isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC);
    final cardBg = isDark ? const Color(0xFF1E293B) : Colors.white;
    final titleColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
    final borderColor = isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0);

    final daysLeft = _daysRemaining(user.expiresAt);
    final isExpired = user.expiresAt.isBefore(DateTime.now());

    return PopScope(
      canPop: !widget.locked,
      child: Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        elevation: 0,
        leading: widget.locked
            ? Icon(Icons.lock_outline, color: subColor, size: 22)
            : IconButton(
                icon: Icon(Icons.close, color: titleColor, size: 24),
                onPressed: () => Navigator.of(context).pop(),
              ),
        title: Text(
          'Renovar Assinatura',
          style: TextStyle(
            color: titleColor,
            fontSize: 17,
            fontWeight: FontWeight.w700,
          ),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          children: [
            // ── TOP CIRCUIT-STYLE BANNER ─────────────────────────────────────
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: isDark
                      ? [const Color(0xFF1E3A8A), const Color(0xFF1E293B)]
                      : [const Color(0xFFEFF6FF), const Color(0xFFDBEAFE)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: isDark ? const Color(0xFF3B82F6) : const Color(0xFF93C5FD),
                  width: 1.2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF2563EB).withValues(alpha: 0.12),
                    blurRadius: 16,
                    offset: const Offset(0, 6),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF2563EB),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.bolt, color: Colors.white, size: 14),
                            SizedBox(width: 4),
                            Text(
                              'LIFO PRO',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: isExpired
                              ? const Color(0xFFEF4444).withValues(alpha: 0.15)
                              : const Color(0xFF059669).withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          isExpired
                              ? 'Expirado'
                              : '$daysLeft dias restantes',
                          style: TextStyle(
                            color: isExpired
                                ? const Color(0xFFEF4444)
                                : const Color(0xFF059669),
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'Desbloqueie todo o potencial do seu veículo',
                    style: TextStyle(
                      color: titleColor,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      height: 1.25,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Sua assinatura atual é válida até ${_formatExpiryDate(user.expiresAt)}. '
                    'Liberação imediata via PIX.',
                    style: TextStyle(
                      color: subColor,
                      fontSize: 13,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // ── CONFIANÇA ("LIBERE E PAGUE") ──────────────────────────────────
            // Expirado que já pagou 1x: +5 dias na confiança. Sem adiantamento
            // aberto e ainda não pagou: aviso (a renovação libera 25 dias).
            if (_canGrace == true) ...[
              _trustCard(
                isDark: isDark,
                cardBg: cardBg,
                titleColor: titleColor,
                subColor: subColor,
              ),
              const SizedBox(height: 20),
            ] else if (_canGrace == false && _gracePending && isExpired) ...[
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF1E293B)
                      : const Color(0xFFFFFBEB),
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: const Color(0xFFD97706).withValues(alpha: 0.4),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.handshake_outlined,
                        size: 22, color: Color(0xFFD97706)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Você usou os 5 dias de confiança. Pague para continuar — '
                        'sua renovação libera 25 dias (5 já usados na confiança).',
                        style: TextStyle(
                          color: titleColor,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
            ],

            // ── PLANOS (toque para selecionar) ───────────────────────────────
            Text(
              'Escolha seu Plano',
              style: TextStyle(
                color: titleColor,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),

            for (final plan in SubscriptionPlan.all) ...[
              _planCard(
                plan: plan,
                selected: plan.id == _selectedPlanId,
                cardBg: cardBg,
                titleColor: titleColor,
                subColor: subColor,
                onTap: () {
                  if (_isLoadingPix) return;
                  HapticFeedback.selectionClick();
                  setState(() => _selectedPlanId = plan.id);
                },
              ),
              const SizedBox(height: 10),
            ],
            const SizedBox(height: 6),

            // ── DADOS DA COBRANÇA (puxados do Supabase) ──────────────────────
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: cardBg,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: borderColor),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.verified_user_outlined,
                          size: 18, color: Color(0xFF2563EB)),
                      const SizedBox(width: 8),
                      Text(
                        'Dados da cobrança',
                        style: TextStyle(
                          color: titleColor,
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const Spacer(),
                      GestureDetector(
                        onTap: () => MyAccountScreen.open(context),
                        child: const Text(
                          'Corrigir',
                          style: TextStyle(
                            color: Color(0xFF2563EB),
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Puxados do Supabase no login e reconferidos na hora do PIX.',
                    style: TextStyle(color: subColor, fontSize: 11),
                  ),
                  const SizedBox(height: 10),
                  _billingLine(Icons.person_outline, 'Nome', user.name.isEmpty ? '—' : user.name, titleColor, subColor),
                  const SizedBox(height: 6),
                  _billingLine(Icons.email_outlined, 'E-mail', user.email.isEmpty ? '—' : user.email, titleColor, subColor),
                  const SizedBox(height: 6),
                  _billingLine(Icons.badge_outlined, 'CPF', _maskCpf(user.cpf), titleColor, subColor),
                  if ((user.phone ?? '').isNotEmpty) ...[
                    const SizedBox(height: 6),
                    _billingLine(Icons.phone_outlined, 'Fone', user.phone!, titleColor, subColor),
                  ],
                  if ((user.cpf ?? '').replaceAll(RegExp(r'\D'), '').isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Row(
                        children: [
                          const Icon(Icons.warning_amber_rounded,
                              size: 16, color: Color(0xFFD97706)),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              'Sem CPF o Asaas recusa (400). Toque em Corrigir e cadastre.',
                              style: TextStyle(
                                color: subColor,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // ── SELOS DE TRANSPARÊNCIA E GARANTIA ─────────────────────────────
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: borderColor),
              ),
              child: Column(
                children: [
                  _buildTrustBadge(
                    icon: Icons.credit_card_off_outlined,
                    text: 'Sem necessidade de cartão de crédito para o teste de 30 dias',
                    subColor: subColor,
                    titleColor: titleColor,
                  ),
                  const SizedBox(height: 8),
                  _buildTrustBadge(
                    icon: Icons.sync_disabled_outlined,
                    text: 'Pagamento único via PIX • Sem cobrança recorrente no cartão',
                    subColor: subColor,
                    titleColor: titleColor,
                  ),
                  const SizedBox(height: 8),
                  _buildTrustBadge(
                    icon: Icons.cancel_outlined,
                    text: 'Cancele a qualquer momento • Sem fidelidade ou taxas extras',
                    subColor: subColor,
                    titleColor: titleColor,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // ── BENEFÍCIOS DO PLANO ──────────────────────────────────────────
            Text(
              'O que está incluso no LIFO Pro:',
              style: TextStyle(
                color: titleColor,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),

            Container(
              decoration: BoxDecoration(
                color: cardBg,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: borderColor),
              ),
              child: Column(
                children: [
                  _buildBenefitRow(
                    icon: Icons.alt_route,
                    title: 'Roteamento OSRM sem Limites',
                    subtitle: 'Cálculo de rotas inteligentes por asfalto com direções reais',
                    titleColor: titleColor,
                    subColor: subColor,
                    borderColor: borderColor,
                  ),
                  _buildBenefitRow(
                    icon: Icons.inventory_2_outlined,
                    title: 'Organização de Carga LIFO (LSO)',
                    subtitle: 'Mapeamento no compartimento do veículo por ordem de entrega',
                    titleColor: titleColor,
                    subColor: subColor,
                    borderColor: borderColor,
                  ),
                  _buildBenefitRow(
                    icon: Icons.qr_code_scanner,
                    title: 'Leitor de Código de Barras via Câmera',
                    subtitle: 'Bipagem e conferência instantânea dos pacotes',
                    titleColor: titleColor,
                    subColor: subColor,
                    borderColor: borderColor,
                  ),
                  _buildBenefitRow(
                    icon: Icons.table_chart_outlined,
                    title: 'Importador de Planilhas',
                    subtitle: 'Suporte a Shopee, Mercado Livre, Amazon, CSV e Excel',
                    titleColor: titleColor,
                    subColor: subColor,
                    borderColor: borderColor,
                  ),
                  _buildBenefitRow(
                    icon: Icons.cloud_done_outlined,
                    title: 'Backup & Sincronização na Nuvem',
                    subtitle: 'Operação 100% offline com backup na nuvem',
                    titleColor: titleColor,
                    subColor: subColor,
                    borderColor: borderColor,
                    isLast: true,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            // ── ÁREA DE PAGAMENTO PIX (takeover animado + ativação automática) ──
            if (_pixResponse == null) ...[
              SizedBox(
                height: 52,
                child: ElevatedButton.icon(
                  icon: _isLoadingPix
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2.2,
                          ),
                        )
                      : const Icon(Icons.pix, color: Colors.white, size: 22),
                  label: Text(
                    _isLoadingPix
                        ? 'Gerando Cobrança PIX...'
                        : 'Pagar ${_selectedPlan.priceBr} via PIX',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF059669),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    elevation: 2,
                  ),
                  onPressed: _isLoadingPix ? null : _generatePixCharge,
                ),
              ),
            ] else ...[
              SizedBox(
                height: 52,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.qr_code_2, color: Colors.white, size: 22),
                  label: const Text(
                    'Ver QR do PIX',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF059669),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    elevation: 2,
                  ),
                  onPressed: () async {
                    final paid = await PixPaymentScreen.open(
                      context,
                      _pixResponse!,
                      plan: _lastChargedPlan,
                    );
                    if (paid && context.mounted) Navigator.of(context).pop();
                  },
                ),
              ),
              const SizedBox(height: 8),
              Center(
                child: TextButton(
                  onPressed: _isLoadingPix ? null : _generatePixCharge,
                  child: const Text(
                    'Gerar um novo PIX',
                    style: TextStyle(
                      color: Color(0xFF64748B),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],

            const SizedBox(height: 24),
          ],
        ),
      ),
      ),
    );
  }

  Widget _trustCard({
    required bool isDark,
    required Color cardBg,
    required Color titleColor,
    required Color subColor,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isDark
              ? [const Color(0xFF065F46), const Color(0xFF064E3B)]
              : [const Color(0xFFECFDF5), const Color(0xFFD1FAE5)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: const Color(0xFF059669).withValues(alpha: 0.5),
          width: 1.2,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Row(
            children: [
              Icon(Icons.handshake_outlined,
                  size: 22, color: Color(0xFF059669)),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Libere e pague (confiança)',
                  style: TextStyle(
                    color: Color(0xFF059669),
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Libere seu app por mais 5 dias, o LIFO confia em você. '
            'Quando você pagar, a renovação libera 25 dias '
            '(5 já usados na confiança).',
            style: TextStyle(
              color: titleColor,
              fontSize: 12.5,
              height: 1.45,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 46,
            child: ElevatedButton.icon(
              icon: _grantingGrace
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                    )
                  : const Icon(Icons.volunteer_activism,
                      color: Colors.white, size: 20),
              label: Text(
                _grantingGrace ? 'Liberando...' : 'Liberar 5 dias na confiança',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF059669),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                elevation: 0,
              ),
              onPressed: _grantingGrace ? null : _takeGrace,
            ),
          ),
        ],
      ),
    );
  }

  Widget _planCard({
    required SubscriptionPlan plan,
    required bool selected,
    required Color cardBg,
    required Color titleColor,
    required Color subColor,
    required VoidCallback onTap,
  }) {
    final accent =
        plan.id == SubscriptionPlan.annual.id ? const Color(0xFF059669) : const Color(0xFF2563EB);
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: cardBg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? accent : const Color(0xFFE2E8F0),
            width: selected ? 2.0 : 1.2,
          ),
          boxShadow: [
            if (selected)
              BoxShadow(
                color: accent.withValues(alpha: 0.10),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
          ],
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? accent : Colors.transparent,
                border: Border.all(
                  color: selected ? accent : const Color(0xFF94A3B8),
                  width: 1.6,
                ),
              ),
              child: selected
                  ? const Icon(Icons.check, color: Colors.white, size: 16)
                  : null,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      Text(
                        plan.title,
                        style: TextStyle(
                          color: titleColor,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (plan.badge != null)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            plan.badge!,
                            style: TextStyle(
                              color: accent,
                              fontSize: 9,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Pagamento via PIX • Liberação Automática',
                    style: TextStyle(
                      color: subColor,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  plan.priceBr,
                  style: TextStyle(
                    color: selected ? accent : titleColor,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  plan.durationLabel,
                  style: TextStyle(
                    color: subColor,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _billingLine(
    IconData icon, String label, String value, Color titleColor, Color subColor) {
    return Row(
      children: [
        Icon(icon, size: 16, color: const Color(0xFF2563EB)),
        const SizedBox(width: 8),
        Text(
          '$label: ',
          style: TextStyle(color: subColor, fontSize: 12, fontWeight: FontWeight.w600),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(color: titleColor, fontSize: 12, fontWeight: FontWeight.w700),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _buildTrustBadge({
    required IconData icon,
    required String text,
    required Color subColor,
    required Color titleColor,
  }) {
    return Row(
      children: [
        Icon(icon, size: 18, color: const Color(0xFF059669)),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: titleColor,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBenefitRow({
    required IconData icon,
    required String title,
    required String subtitle,
    required Color titleColor,
    required Color subColor,
    required Color borderColor,
    bool isLast = false,
  }) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: const Color(0xFF2563EB).withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: const Color(0xFF2563EB), size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: titleColor,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: subColor,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.check_circle,
                color: Color(0xFF059669),
                size: 18,
              ),
            ],
          ),
        ),
        if (!isLast) Divider(color: borderColor, height: 1),
      ],
    );
  }

}
