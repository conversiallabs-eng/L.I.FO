import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/models/manifest_version.dart';

/// Tela azul de resumo exibida após importar o manifesto com a rota
/// otimizada: paradas, pacotes, distância, estimativa de término e o
/// comparativo "você economizou X km com o LIFO".
///
/// Entrada coreografada (selo → stats → economia → botão) e saída animada.
/// "Ver no mapa" retorna true para o chamador reenquadrar com animação.
class ImportSuccessDialog extends StatefulWidget {
  final ManifestVersion version;
  final double totalDurationSeconds;
  final DateTime? routeComputedAt;
  final double totalDistanceMeters;
  final double originalDistanceMeters;

  const ImportSuccessDialog({
    super.key,
    required this.version,
    required this.totalDurationSeconds,
    required this.routeComputedAt,
    required this.totalDistanceMeters,
    this.originalDistanceMeters = 0,
  });

  /// Retorna true quando toca em "Ver no mapa".
  static Future<bool?> show(
    BuildContext context, {
    required ManifestVersion version,
    required double totalDurationSeconds,
    required DateTime? routeComputedAt,
    required double totalDistanceMeters,
    double originalDistanceMeters = 0,
  }) {
    return showGeneralDialog<bool>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Fechar resumo da rota',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 380),
      pageBuilder: (dialogCtx, anim, secondaryAnim) => ImportSuccessDialog(
        version: version,
        totalDurationSeconds: totalDurationSeconds,
        routeComputedAt: routeComputedAt,
        totalDistanceMeters: totalDistanceMeters,
        originalDistanceMeters: originalDistanceMeters,
      ),
      transitionBuilder: (dialogCtx, animation, secondaryAnim, child) {
        final curved =
            CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.88, end: 1.0).animate(curved),
            child: child,
          ),
        );
      },
    );
  }

  @override
  State<ImportSuccessDialog> createState() => _ImportSuccessDialogState();
}

class _ImportSuccessDialogState extends State<ImportSuccessDialog>
    with SingleTickerProviderStateMixin {
  late final AnimationController _enter;

  late final Animation<double> _opSeal;
  late final Animation<double> _scaleSeal;
  late final Animation<double> _opStats1;
  late final Animation<Offset> _slideStats1;
  late final Animation<double> _opStats2;
  late final Animation<Offset> _slideStats2;
  late final Animation<double> _opSave;
  late final Animation<Offset> _slideSave;
  late final Animation<double> _opButton;

  @override
  void initState() {
    super.initState();
    _enter = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
    _opSeal = _fade(0.0, 0.22);
    _scaleSeal = Tween<double>(begin: 0.55, end: 1.0).animate(
      CurvedAnimation(
          parent: _enter,
          curve: const Interval(0.0, 0.30, curve: Curves.easeOutBack)),
    );
    _opStats1 = _fade(0.18, 0.42);
    _slideStats1 = _slide(0.18, 0.42);
    _opStats2 = _fade(0.34, 0.58);
    _slideStats2 = _slide(0.34, 0.58);
    _opSave = _fade(0.52, 0.78);
    _slideSave = _slide(0.52, 0.78);
    _opButton = _fade(0.70, 1.0);
    _enter.forward();
    HapticFeedback.mediumImpact();
  }

  Animation<double> _fade(double begin, double end) =>
      Tween<double>(begin: 0, end: 1).animate(
        CurvedAnimation(
            parent: _enter,
            curve: Interval(begin, end, curve: Curves.easeOutCubic)),
      );

  Animation<Offset> _slide(double begin, double end) =>
      Tween<Offset>(begin: const Offset(0, 0.25), end: Offset.zero).animate(
        CurvedAnimation(
            parent: _enter,
            curve: Interval(begin, end, curve: Curves.easeOutCubic)),
      );

  @override
  void dispose() {
    _enter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final stops = widget.version.stops.length;
    final packages = widget.version.totalPackagesInStops;
    final hasEta =
        widget.totalDurationSeconds > 0 && widget.routeComputedAt != null;
    final arrival = hasEta
        ? widget.routeComputedAt!
            .add(Duration(seconds: widget.totalDurationSeconds.round()))
        : null;
    final durationLabel = _durationLabel(widget.totalDurationSeconds);
    final distanceKm = widget.totalDistanceMeters / 1000;

    // Comparativo honesto: mesma origem (GPS), ordem do arquivo vs otimizada.
    final savedMeters =
        widget.originalDistanceMeters - widget.totalDistanceMeters;
    final showSavings = widget.originalDistanceMeters > 0 &&
        widget.totalDistanceMeters > 0 &&
        savedMeters > 50;
    final savePct = showSavings
        ? (savedMeters / widget.originalDistanceMeters * 100).round()
        : 0;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      elevation: 0,
      backgroundColor: Colors.transparent,
      insetPadding:
          const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      child: Container(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [AppColors.circuitBlue, AppColors.circuitBlueGlow],
          ),
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: AppColors.circuitBlue.withValues(alpha: 0.5),
              blurRadius: 32,
              spreadRadius: 4,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              FadeTransition(
                opacity: _opSeal,
                child: ScaleTransition(
                  scale: _scaleSeal,
                  child: Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withValues(alpha: 0.2),
                      border: Border.all(color: Colors.white, width: 2.5),
                    ),
                    child: const Icon(Icons.check,
                        color: Colors.white, size: 34),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              FadeTransition(
                opacity: _opSeal,
                child: const Text(
                  'Rota otimizada!',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              FadeTransition(
                opacity: _opSeal,
                child: Text(
                  widget.version.label,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.85),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              FadeTransition(
                opacity: _opStats1,
                child: SlideTransition(
                  position: _slideStats1,
                  child: Row(
                    children: [
                      Expanded(
                        child: _StatBox(
                          icon: Icons.location_on_outlined,
                          value: '$stops',
                          label: stops == 1 ? 'parada' : 'paradas',
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _StatBox(
                          icon: Icons.inventory_2_outlined,
                          value: '$packages',
                          label: packages == 1 ? 'pacote' : 'pacotes',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              FadeTransition(
                opacity: _opStats2,
                child: SlideTransition(
                  position: _slideStats2,
                  child: Row(
                    children: [
                      Expanded(
                        child: _StatBox(
                          icon: Icons.route_outlined,
                          value: widget.totalDistanceMeters > 0
                              ? '${distanceKm.toStringAsFixed(1)} km'
                              : '—',
                          label: 'trajeto',
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _StatBox(
                          icon: Icons.schedule_outlined,
                          value: arrival != null
                              ? DateFormat('HH:mm').format(arrival)
                              : '—',
                          label: arrival != null
                              ? 'término ≈ $durationLabel'
                              : 'sem estimativa',
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (showSavings) ...[
                const SizedBox(height: 10),
                FadeTransition(
                  opacity: _opSave,
                  child: SlideTransition(
                    position: _slideSave,
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF16A34A).withValues(alpha: 0.28),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.45),
                          width: 1.2,
                        ),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 38,
                            height: 38,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color:
                                  Colors.white.withValues(alpha: 0.22),
                            ),
                            child: const Icon(
                              Icons.eco_outlined,
                              color: Colors.white,
                              size: 22,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment.start,
                              children: [
                                TweenAnimationBuilder<double>(
                                  tween: Tween(
                                      begin: 0, end: savedMeters / 1000),
                                  duration:
                                      const Duration(milliseconds: 900),
                                  curve: Curves.easeOutCubic,
                                  builder: (ctx, value, child) => Text(
                                    'Você economizou ${value.toStringAsFixed(1)} km com o LIFO',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '$savePct% a menos de rua que a ordem do manifesto',
                                  style: TextStyle(
                                    color: Colors.white
                                        .withValues(alpha: 0.85),
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 20),
              FadeTransition(
                opacity: _opButton,
                child: SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: AppColors.circuitBlue,
                      padding:
                          const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: () {
                      HapticFeedback.lightImpact();
                      Navigator.of(context).pop(true);
                    },
                    child: const Text(
                      'Ver no mapa',
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w800),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _durationLabel(double seconds) {
    if (seconds <= 0) return '';
    final totalMin = (seconds / 60).round();
    final h = totalMin ~/ 60;
    final m = totalMin % 60;
    if (h == 0) return '${m}min';
    if (m == 0) return '${h}h';
    return '${h}h${m.toString().padLeft(2, '0')}';
  }
}

class _StatBox extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;

  const _StatBox({
    required this.icon,
    required this.value,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.35),
          width: 1.2,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 22),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.85),
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
