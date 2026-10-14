import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../controllers/auth_controller.dart';
import '../../data/services/asaas_payment_service.dart';
import 'my_account_screen.dart';

class SubscriptionRenewalScreen extends ConsumerStatefulWidget {
  const SubscriptionRenewalScreen({super.key});

  static Future<void> open(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const SubscriptionRenewalScreen(),
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
  bool _isVerifying = false;
  AsaasPixChargeResponse? _pixResponse;

  /// Decodifica o QR base64 vindo do Asaas (com ou sem prefixo data URI).
  ImageProvider? _qrImage() {
    final b64 = _pixResponse?.qrCodeBase64;
    if (b64 == null || b64.isEmpty) return null;
    try {
      final clean = b64.contains(',') ? b64.split(',').last : b64;
      return MemoryImage(base64Decode(clean));
    } catch (_) {
      return null;
    }
  }

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

  Future<void> _generatePixCharge() async {
    setState(() {
      _isLoadingPix = true;
    });
    HapticFeedback.mediumImpact();

    final user = ref.read(authControllerProvider).user;
    try {
      final pix = await AsaasPaymentService.instance.createPixCharge(
        user: user,
        amount: 19.90,
      );

      if (mounted) {
        setState(() {
          _pixResponse = pix;
          _isLoadingPix = false;
        });
        HapticFeedback.lightImpact();
      }
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

  void _copyPixCode(String code) {
    Clipboard.setData(ClipboardData(text: code));
    HapticFeedback.selectionClick();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Row(
          children: [
            Icon(Icons.check_circle, color: Colors.white, size: 20),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'Código PIX copiado! Cole no aplicativo do seu banco.',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
              ),
            ),
          ],
        ),
        backgroundColor: const Color(0xFF059669),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Future<void> _confirmAndRenew() async {
    setState(() {
      _isVerifying = true;
    });
    HapticFeedback.mediumImpact();

    // Só renova com pagamento CONFIRMADO no Asaas (ou liberado via webhook).
    bool paid = false;
    if (_pixResponse != null) {
      paid = await AsaasPaymentService.instance.checkPaymentStatus(
        paymentId: _pixResponse!.paymentId,
      );
    }

    if (!mounted) return;
    setState(() {
      _isVerifying = false;
    });

    if (!paid) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Row(
            children: [
              Icon(Icons.hourglass_bottom, color: Colors.white, size: 20),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Pagamento ainda não identificado. Pague o PIX e aguarde ~1 min antes de confirmar.',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                ),
              ),
            ],
          ),
          backgroundColor: Color(0xFFD97706),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 5),
        ),
      );
      return;
    }

    await ref.read(authControllerProvider.notifier).renewSubscription();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Row(
            children: [
              Icon(Icons.verified, color: Colors.white, size: 22),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  '🎉 Assinatura renovada com sucesso! +30 dias ativados.',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                ),
              ),
            ],
          ),
          backgroundColor: const Color(0xFF2563EB),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          duration: const Duration(seconds: 4),
        ),
      );

      Navigator.of(context).pop();
    }
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

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        elevation: 0,
        leading: IconButton(
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
                    'Renove por mais 30 dias com liberação imediata via PIX.',
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

            // ── CARTÃO DO PLANO SELECIONADO (CIRCUIT DESIGN) ────────────────
            Text(
              'Escolha seu Plano',
              style: TextStyle(
                color: titleColor,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),

            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: cardBg,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: const Color(0xFF2563EB),
                  width: 2.0,
                ),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF2563EB).withValues(alpha: 0.08),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Container(
                    width: 24,
                    height: 24,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Color(0xFF2563EB),
                    ),
                    child: const Icon(
                      Icons.check,
                      color: Colors.white,
                      size: 16,
                    ),
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
                              'Plano Mensal (30 Dias)',
                              style: TextStyle(
                                color: titleColor,
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFF10B981).withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: const Text(
                                'RECOMENDADO',
                                style: TextStyle(
                                  color: Color(0xFF059669),
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
                      const Text(
                        'R\$ 19,90',
                        style: TextStyle(
                          color: Color(0xFF2563EB),
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        '/30 dias',
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
            const SizedBox(height: 16),

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

            // ── ÁREA DE PAGAMENTO PIX ──────────────────────────────────────────
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
                        : 'Pagar R\$ 19,90 via PIX',
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
              // CONTAINER COM O CÓDIGO PIX GERADO
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: const Color(0xFF059669),
                    width: 1.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF059669).withValues(alpha: 0.1),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.pix, color: Color(0xFF059669), size: 24),
                        const SizedBox(width: 8),
                        Text(
                          'Cobrança PIX Gerada',
                          style: TextStyle(
                            color: titleColor,
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    // QR CODE DO PIX (base64 vindo do Asaas)
                    Builder(
                      builder: (context) {
                        final qr = _qrImage();
                        if (qr == null) {
                          return const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  color: Color(0xFF059669),
                                  strokeWidth: 2,
                                ),
                              ),
                              SizedBox(width: 10),
                              Text('Gerando QR Code...'),
                            ],
                          );
                        }
                        return TweenAnimationBuilder<double>(
                          tween: Tween(begin: 0.7, end: 1.0),
                          duration: const Duration(milliseconds: 600),
                          curve: Curves.easeOutBack,
                          builder: (context, scale, child) =>
                              Transform.scale(scale: scale, child: child),
                          child: Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: const Color(0xFF059669),
                                width: 1.5,
                              ),
                            ),
                            child: Image(
                              image: qr,
                              width: 210,
                              height: 210,
                              fit: BoxFit.contain,
                            ),
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Escaneie com o app do banco ou use o copia e cola:',
                      style: TextStyle(
                        color: subColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Badge do Valor
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF059669).withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Text(
                        'Valor: R\$ 19,90 • Validade: 24h',
                        style: TextStyle(
                          color: Color(0xFF059669),
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // CAMPO COPIA E COLA PIX
                    Text(
                      'Código PIX Copia e Cola:',
                      style: TextStyle(
                        color: subColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),

                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: borderColor),
                      ),
                      child: SelectableText(
                        _pixResponse!.copyAndPastePix,
                        style: TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                          color: titleColor,
                        ),
                        maxLines: 2,
                      ),
                    ),
                    const SizedBox(height: 12),

                    // BOTÃO COPIAR CÓDIGO
                    SizedBox(
                      width: double.infinity,
                      height: 44,
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.copy, size: 18, color: Colors.white),
                        label: const Text(
                          'Copiar Código PIX',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF2563EB),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        onPressed: () => _copyPixCode(_pixResponse!.copyAndPastePix),
                      ),
                    ),
                    const SizedBox(height: 16),

                    const Divider(),
                    const SizedBox(height: 10),

                    // INSTRUÇÕES DE PAGAMENTO
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildInstructionStep('1', 'Copie o código PIX acima.'),
                        _buildInstructionStep('2', 'Abra o aplicativo do seu banco.'),
                        _buildInstructionStep('3', 'Escolha a opção PIX Copia e Cola.'),
                        _buildInstructionStep('4', 'Confirme o pagamento de R\$ 19,90.'),
                      ],
                    ),
                    const SizedBox(height: 18),

                    // BOTÃO DE CONFIRMAÇÃO / SIMULAÇÃO
                    SizedBox(
                      width: double.infinity,
                      height: 48,
                      child: ElevatedButton.icon(
                        icon: _isVerifying
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.check_circle_outline, color: Colors.white, size: 20),
                        label: Text(
                          _isVerifying
                              ? 'Confirmando Pagamento...'
                              : 'Já Realizei o Pagamento / Confirmar',
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
                        ),
                        onPressed: _isVerifying ? null : _confirmAndRenew,
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 24),
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

  Widget _buildInstructionStep(String number, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
            width: 20,
            height: 20,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Color(0xFF2563EB),
            ),
            child: Center(
              child: Text(
                number,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
