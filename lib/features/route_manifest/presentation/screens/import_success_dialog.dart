import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../../core/theme/app_colors.dart';
import '../../domain/models/manifest_version.dart';

/// Tela azul de resumo exibida após importar o manifesto com a rota
/// otimizada: paradas, pacotes, distância e estimativa de término.
class ImportSuccessDialog extends StatelessWidget {
  final ManifestVersion version;
  final double totalDurationSeconds;
  final DateTime? routeComputedAt;
  final double totalDistanceMeters;

  const ImportSuccessDialog({
    super.key,
    required this.version,
    required this.totalDurationSeconds,
    required this.routeComputedAt,
    required this.totalDistanceMeters,
  });

  static Future<void> show(
    BuildContext context, {
    required ManifestVersion version,
    required double totalDurationSeconds,
    required DateTime? routeComputedAt,
    required double totalDistanceMeters,
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (_) => ImportSuccessDialog(
        version: version,
        totalDurationSeconds: totalDurationSeconds,
        routeComputedAt: routeComputedAt,
        totalDistanceMeters: totalDistanceMeters,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final stops = version.stops.length;
    final packages = version.totalPackagesInStops;
    final hasEta = totalDurationSeconds > 0 && routeComputedAt != null;
    final arrival = hasEta
        ? routeComputedAt!.add(Duration(seconds: totalDurationSeconds.round()))
        : null;
    final durationLabel = _durationLabel(totalDurationSeconds);
    final distanceKm = totalDistanceMeters / 1000;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      elevation: 0,
      backgroundColor: Colors.transparent,
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.2),
                border: Border.all(color: Colors.white, width: 2.5),
              ),
              child: const Icon(Icons.check, color: Colors.white, size: 34),
            ),
            const SizedBox(height: 14),
            const Text(
              'Rota otimizada!',
              style: TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w900,
                letterSpacing: 0.2,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              version.label,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.85),
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 20),
            Row(
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
            ),            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _StatBox(
                    icon: Icons.route_outlined,
                    value: totalDistanceMeters > 0
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
                    label: arrival != null ? 'término ≈ $durationLabel' : 'sem estimativa',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: AppColors.circuitBlue,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                onPressed: () => Navigator.of(context).pop(),
                child: const Text(
                  'Ver no mapa',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                ),
              ),
            ),
          ],
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
