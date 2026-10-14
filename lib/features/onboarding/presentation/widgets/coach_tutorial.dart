import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Um passo do tutorial apontando para um widget REAL da tela.
class CoachStep {
  final GlobalKey targetKey;
  final String title;
  final String body;

  const CoachStep({
    required this.targetKey,
    required this.title,
    required this.body,
  });
}

/// Overlay de tutorial com holofote: escurece a tela, recorta o widget alvo
/// com borda pulsante e mostra o balão explicativo. Funciona sobre QUALQUER
/// tela, sem mudar nada nela — só precisa da GlobalKey do alvo.
class CoachTutorial extends StatefulWidget {
  final List<CoachStep> steps;

  const CoachTutorial({super.key, required this.steps});

  static Future<void> show(BuildContext context, List<CoachStep> steps) {
    if (steps.isEmpty) return Future.value();
    return Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierDismissible: false,
        transitionDuration: const Duration(milliseconds: 280),
        reverseTransitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (ctx, anim, secondaryAnim) =>
            CoachTutorial(steps: steps),
        transitionsBuilder: (ctx, anim, secondaryAnim, child) =>
            FadeTransition(opacity: anim, child: child),
      ),
    );
  }

  @override
  State<CoachTutorial> createState() => _CoachTutorialState();
}

class _CoachTutorialState extends State<CoachTutorial>
    with SingleTickerProviderStateMixin {
  int _index = 0;
  Rect? _hole;
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  Rect? _rectOf(GlobalKey key) {
    try {
      final ctx = key.currentContext;
      if (ctx == null) return null;
      final box = ctx.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize || box.size.isEmpty) return null;
      return box.localToGlobal(Offset.zero) & box.size;
    } catch (_) {
      return null;
    }
  }

  /// Mede o alvo atual; se sumiu, pula para o próximo com alvo válido.
  /// Se nenhum restar, fecha sozinho.
  void _measure() {
    if (!mounted) return;
    var i = _index;
    Rect? rect;
    while (i < widget.steps.length) {
      rect = _rectOf(widget.steps[i].targetKey);
      if (rect != null) break;
      i++;
    }
    if (!mounted) return;
    if (rect == null) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _index = i;
      _hole = rect;
    });
  }

  void _go(int i) {
    HapticFeedback.selectionClick();
    if (i >= widget.steps.length) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _index = i;
      _hole = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final padding = MediaQuery.of(context).padding;
    final step = widget.steps[_index.clamp(0, widget.steps.length - 1)];
    final hole = _hole;
    final isLast = _index == widget.steps.length - 1;

    // Balão: embaixo do alvo se couber, senão em cima.
    double? tipTop;
    if (hole != null) {
      const tipH = 250.0;
      tipTop = (hole.bottom + 16 + tipH < size.height)
          ? hole.bottom + 16
          : (hole.top - 16 - tipH).clamp(padding.top + 8, size.height - tipH - 16);
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final cardBg = isDark ? const Color(0xFF1E293B) : Colors.white;
    final titleColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // Scrim + holofote (toque fora do balão avança).
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _go(_index + 1),
              child: AnimatedBuilder(
                animation: _pulse,
                builder: (ctx, child) => CustomPaint(
                  painter: _SpotlightPainter(
                    hole: hole,
                    pulse: _pulse.value,
                  ),
                ),
              ),
            ),
          ),
          // Balão explicativo.
          if (hole != null)
            Positioned(
              left: 20,
              right: 20,
              top: tipTop,
              child: Container(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: const Color(0xFF2563EB).withValues(alpha: 0.4),
                    width: 1.2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.4),
                      blurRadius: 20,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      step.title,
                      style: TextStyle(
                        color: titleColor,
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      step.body,
                      style: TextStyle(
                        color: subColor,
                        fontSize: 13.5,
                        height: 1.45,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Text(
                            'Pular',
                            style: TextStyle(
                              color: Color(0xFF94A3B8),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const Spacer(),
                        // Dots
                        Row(
                          children: [
                            for (int i = 0; i < widget.steps.length; i++)
                              Container(
                                width: i == _index ? 18 : 6,
                                height: 6,
                                margin: const EdgeInsets.symmetric(horizontal: 2),
                                decoration: BoxDecoration(
                                  color: i == _index
                                      ? const Color(0xFF2563EB)
                                      : const Color(0xFF94A3B8)
                                          .withValues(alpha: 0.4),
                                  borderRadius: BorderRadius.circular(3),
                                ),
                              ),
                          ],
                        ),
                        const Spacer(),
                        if (_index > 0)
                          TextButton(
                            onPressed: () => _go(_index - 1),
                            child: const Text(
                              'Voltar',
                              style: TextStyle(
                                color: Color(0xFF2563EB),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF2563EB),
                            foregroundColor: Colors.white,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          onPressed: () => _go(_index + 1),
                          child: Text(isLast ? 'Entendi!' : 'Próximo'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SpotlightPainter extends CustomPainter {
  final Rect? hole;
  final double pulse;

  _SpotlightPainter({required this.hole, required this.pulse});

  @override
  void paint(Canvas canvas, Size size) {
    final full = Rect.fromLTWH(0, 0, size.width, size.height);
    final h = hole;
    if (h == null) {
      canvas.drawRect(
        full,
        Paint()..color = Colors.black.withValues(alpha: 0.62),
      );
      return;
    }
    // Recorta o alvo (cantos arredondados) — clear exige saveLayer.
    final rrect = RRect.fromRectAndRadius(h.inflate(6), const Radius.circular(14));
    canvas.saveLayer(full, Paint());
    canvas.drawRect(
      full,
      Paint()..color = Colors.black.withValues(alpha: 0.62),
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..blendMode = BlendMode.clear
        ..style = PaintingStyle.fill,
    );
    canvas.restore();
    // Borda pulsante no alvo.
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = Color.lerp(
          const Color(0xFF60A5FA),
          const Color(0xFFFFFFFF),
          pulse,
        )!,
    );
  }

  @override
  bool shouldRepaint(covariant _SpotlightPainter old) =>
      old.hole != hole || old.pulse != pulse;
}
