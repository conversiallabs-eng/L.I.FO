import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../controllers/auth_controller.dart';
import '../../data/services/asaas_payment_service.dart';

/// Takeover de pagamento PIX estilo Nubank/Mercado Pago.
///
/// Entra com cascata de animações (valor → QR com scan → campos), fica
/// sondando o Asaas sozinha a cada 8s e, ao detectar o pagamento,
/// toca a animação de sucesso e renova a assinatura — zero botão manual.
class PixPaymentScreen extends ConsumerStatefulWidget {
  final AsaasPixChargeResponse pix;

  const PixPaymentScreen({super.key, required this.pix});

  /// Abre em tela cheia. Retorna true se o pagamento foi aprovado.
  static Future<bool> open(BuildContext context, AsaasPixChargeResponse pix) {
    return Navigator.of(context)
        .push<bool>(
          MaterialPageRoute(
            builder: (_) => PixPaymentScreen(pix: pix),
            fullscreenDialog: true,
          ),
        )
        .then((v) => v ?? false);
  }

  @override
  ConsumerState<PixPaymentScreen> createState() => _PixPaymentScreenState();
}

class _PixPaymentScreenState extends ConsumerState<PixPaymentScreen>
    with TickerProviderStateMixin {
  late final AnimationController _enter;
  late final Animation<double> _opAmount;
  late final Animation<Offset> _slideAmount;
  late final Animation<double> _opQr;
  late final Animation<double> _scaleQr;
  late final Animation<double> _opRest;

  late final AnimationController _scan; // linha de scan em loop
  late final AnimationController _pulse; // anel pulsante do status
  late final AnimationController _success; // pop do check

  Timer? _pollTimer;
  Timer? _clockTimer;
  Duration _remaining = Duration.zero;
  bool _checkingNow = false;
  bool _paid = false;
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    _enter = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 950),
    );
    _opAmount = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _enter, curve: const Interval(0.0, 0.35, curve: Curves.easeOutCubic)),
    );
    _slideAmount = Tween<Offset>(begin: const Offset(0, 0.4), end: Offset.zero).animate(
      CurvedAnimation(parent: _enter, curve: const Interval(0.0, 0.35, curve: Curves.easeOutCubic)),
    );
    _opQr = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _enter, curve: const Interval(0.25, 0.6, curve: Curves.easeOutCubic)),
    );
    _scaleQr = Tween<double>(begin: 0.6, end: 1.0).animate(
      CurvedAnimation(parent: _enter, curve: const Interval(0.25, 0.65, curve: Curves.easeOutBack)),
    );
    _opRest = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _enter, curve: const Interval(0.55, 1.0, curve: Curves.easeOutCubic)),
    );
    _enter.forward();

    _scan = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat(reverse: true);

    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();

    _success = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );

    _tickClock();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) => _tickClock());

    // Sondagem automática: 1ª aos 5s, depois a cada 8s.
    _pollTimer = Timer(const Duration(seconds: 5), () {
      _pollOnce();
      _pollTimer = Timer.periodic(const Duration(seconds: 8), (_) => _pollOnce());
    });
  }

  void _tickClock() {
    if (!mounted || _paid) return;
    setState(() {
      _remaining = widget.pix.expirationDate.difference(DateTime.now());
    });
  }

  Future<void> _pollOnce() async {
    if (!mounted || _paid || _checkingNow) return;
    setState(() => _checkingNow = true);
    bool paid = false;
    try {
      paid = await AsaasPaymentService.instance.checkPaymentStatus(
        paymentId: widget.pix.paymentId,
      );
    } catch (_) {}
    if (!mounted) return;
    setState(() => _checkingNow = false);
    if (paid) _onPaid();
  }

  Future<void> _onPaid() async {
    if (_paid) return;
    setState(() => _paid = true);
    HapticFeedback.heavyImpact();
    _pollTimer?.cancel();
    _clockTimer?.cancel();
    _scan.stop();
    _pulse.stop();
    _success.forward(from: 0);

    // O webhook já ativou no servidor; espelha no app.
    try {
      await ref.read(authControllerProvider.notifier).renewSubscription();
    } catch (_) {}

    await Future.delayed(const Duration(milliseconds: 2600));
    if (mounted) Navigator.of(context).pop(true);
  }

  ImageProvider? _qrImage() {
    final b64 = widget.pix.qrCodeBase64;
    if (b64 == null || b64.isEmpty) return null;
    try {
      final clean = b64.contains(',') ? b64.split(',').last : b64;
      return MemoryImage(base64Decode(clean));
    } catch (_) {
      return null;
    }
  }

  String _formatRemaining() {
    if (_remaining.isNegative) return '00:00:00';
    final h = _remaining.inHours.toString().padLeft(2, '0');
    final m = (_remaining.inMinutes % 60).toString().padLeft(2, '0');
    final s = (_remaining.inSeconds % 60).toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  void _copy() {
    Clipboard.setData(ClipboardData(text: widget.pix.copyAndPastePix));
    HapticFeedback.selectionClick();
    setState(() => _copied = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _clockTimer?.cancel();
    _enter.dispose();
    _scan.dispose();
    _pulse.dispose();
    _success.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC);
    final cardBg = isDark ? const Color(0xFF1E293B) : Colors.white;
    final titleColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
    final borderColor = isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0);

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        elevation: 0,
        leading: _paid
            ? null
            : IconButton(
                icon: Icon(Icons.close, color: titleColor, size: 24),
                onPressed: () => Navigator.of(context).pop(false),
              ),
        title: Text(
          'Pagamento via PIX',
          style: TextStyle(color: titleColor, fontSize: 17, fontWeight: FontWeight.w700),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 450),
          switchInCurve: Curves.easeOutCubic,
          transitionBuilder: (child, anim) =>
              FadeTransition(opacity: anim, child: ScaleTransition(scale: anim, child: child)),
          child: _paid
              ? _buildSuccess()
              : _buildPaying(cardBg, titleColor, subColor, borderColor, isDark),
        ),
      ),
    );
  }

  // ── ESTADO: aguardando pagamento ──────────────────────────────────────────
  Widget _buildPaying(
    Color cardBg, Color titleColor, Color subColor, Color borderColor, bool isDark) {
    final expired = _remaining.isNegative;
    return ListView(
      physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      children: [
        // Valor — entra primeiro
        FadeTransition(
          opacity: _opAmount,
          child: SlideTransition(
            position: _slideAmount,
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                      decoration: BoxDecoration(
                        color: const Color(0xFF059669).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.pix, size: 14, color: Color(0xFF059669)),
                          SizedBox(width: 5),
                          Text(
                            'LIFO PRO • 30 DIAS',
                            style: TextStyle(
                              color: Color(0xFF059669),
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.6,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  'R\$ 19,90',
                  style: TextStyle(
                    color: titleColor,
                    fontSize: 44,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -1,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 18),

        // QR — entra com pop elástico + scan em loop
        FadeTransition(
          opacity: _opQr,
          child: ScaleTransition(
            scale: _scaleQr,
            child: RepaintBoundary(
              child: Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: const Color(0xFF059669), width: 1.6),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF059669).withValues(alpha: 0.16),
                      blurRadius: 24,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    SizedBox(
                      width: 232,
                      height: 232,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Builder(
                            builder: (_) {
                              final qr = _qrImage();
                              if (qr == null) {
                                return const CircularProgressIndicator(
                                  color: Color(0xFF059669),
                                );
                              }
                              return Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(16),
                                ),
                                child: Image(image: qr, width: 212, height: 212),
                              );
                            },
                          ),
                          // Linha de scan passeando (só enquanto aguarda)
                          if (!expired)
                            AnimatedBuilder(
                              animation: _scan,
                              builder: (_, child) => Positioned(
                                top: 12 + _scan.value * 196,
                                left: 16,
                                right: 16,
                                child: Container(
                                  height: 3,
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(2),
                                    gradient: const LinearGradient(
                                      colors: [
                                        Colors.transparent,
                                        Color(0xFF10B981),
                                        Colors.transparent,
                                      ],
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: const Color(0xFF10B981).withValues(alpha: 0.7),
                                        blurRadius: 12,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    // Pílula de status pulsante
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(
                        color: (expired ? const Color(0xFFDC2626) : const Color(0xFF059669))
                            .withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AnimatedBuilder(
                            animation: _pulse,
                            builder: (_, child) => Container(
                              width: 9,
                              height: 9,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: (expired
                                        ? const Color(0xFFDC2626)
                                        : const Color(0xFF059669))
                                    .withValues(alpha: 0.45 + 0.55 * (0.5 + 0.5 * _pulse.value)),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            expired
                                ? 'PIX expirado — gere um novo'
                                : 'Aguardando pagamento${'.' * (1 + (_pulse.value * 2.99).floor())}',
                            style: TextStyle(
                              color: expired
                                  ? const Color(0xFFDC2626)
                                  : const Color(0xFF059669),
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (!expired) ...[
                      const SizedBox(height: 6),
                      Text(
                        'Expira em ${_formatRemaining()}',
                        style: TextStyle(
                          color: subColor,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),

        // Resto — entra por último
        FadeTransition(
          opacity: _opRest,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'PIX copia e cola',
                style: TextStyle(color: subColor, fontSize: 12, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: borderColor),
                ),
                child: SelectableText(
                  widget.pix.copyAndPastePix,
                  style: TextStyle(fontFamily: 'monospace', fontSize: 11, color: titleColor),
                  maxLines: 3,
                  minLines: 1,
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 48,
                child: ElevatedButton.icon(
                  icon: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: _copied
                        ? const Icon(Icons.check, key: ValueKey('ok'), size: 19, color: Colors.white)
                        : const Icon(Icons.copy, key: ValueKey('cp'), size: 18, color: Colors.white),
                  ),
                  label: Text(
                    _copied ? 'Copiado!' : 'Copiar código PIX',
                    style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w700),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        _copied ? const Color(0xFF059669) : const Color(0xFF2563EB),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    elevation: 0,
                  ),
                  onPressed: _copy,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                'Escaneie com o app do banco ou cole o código. A confirmação é automática — pode fechar esta tela, avisamos quando aprovar.',
                textAlign: TextAlign.center,
                style: TextStyle(color: subColor, fontSize: 12, height: 1.45),
              ),
              const SizedBox(height: 6),
              Center(
                child: _checkingNow
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color(0xFF059669),
                        ),
                      )
                    : TextButton(
                        onPressed: _pollOnce,
                        child: const Text(
                          'Verificar agora',
                          style: TextStyle(
                            color: Color(0xFF059669),
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── ESTADO: pagamento aprovado (festa) ────────────────────────────────────
  Widget _buildSuccess() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 190,
              height: 190,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Anéis expansivos
                  for (int i = 0; i < 2; i++)
                    AnimatedBuilder(
                      animation: _success,
                      builder: (_, child) {
                        final t = ((_success.value * 1.4 - i * 0.35).clamp(0.0, 1.0));
                        return Opacity(
                          opacity: (1 - t) * 0.5,
                          child: Transform.scale(
                            scale: 0.55 + t * 0.75,
                            child: Container(
                              width: 150,
                              height: 150,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: const Color(0xFF10B981),
                                  width: 3,
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  // Selo com pop elástico
                  ScaleTransition(
                    scale: Tween<double>(begin: 0.3, end: 1.0).animate(
                      CurvedAnimation(parent: _success, curve: Curves.easeOutBack),
                    ),
                    child: Container(
                      width: 110,
                      height: 110,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: const LinearGradient(
                          colors: [Color(0xFF10B981), Color(0xFF059669)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF059669).withValues(alpha: 0.45),
                            blurRadius: 28,
                            offset: const Offset(0, 10),
                          ),
                        ],
                      ),
                      child: const Icon(Icons.check, color: Colors.white, size: 58),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 22),
            FadeTransition(
              opacity: _success,
              child: const Column(
                children: [
                  Text(
                    'Pagamento aprovado!',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Assinatura LIFO Pro ativada • +30 dias',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
