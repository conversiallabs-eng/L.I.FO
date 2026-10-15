import 'package:latlong2/latlong.dart';

/// Simplificação de polyline p/ RENDER (Fase 3b perf): Douglas-Peucker.
///
/// A geometria CHEIA continua no estado/banco/lógica de manobra; só o
/// desenho usa a versão simplificada (pura, sem estado). Tolerância padrão
/// ~9 m: invisível em z10–17 e corta 60–80% dos pontos do OSRM `full`.
/// Sempre preserva primeiro e último ponto. Iterativo (sem recursão) para
/// nunca estourar stack com geometria longa.
class RouteSimplify {
  /// ~9 m em graus (1° lat ≈ 111 km).
  static const double defaultToleranceDeg = 0.00008;

  static List<LatLng> douglasPeucker(
    List<LatLng> points, {
    double toleranceDeg = defaultToleranceDeg,
  }) {
    if (points.length < 3) return points;
    final keep = List<bool>.filled(points.length, false);
    keep[0] = true;
    keep[points.length - 1] = true;

    final tolSq = toleranceDeg * toleranceDeg;
    final stack = <(int, int)>[(0, points.length - 1)];
    while (stack.isNotEmpty) {
      final (first, last) = stack.removeLast();
      double maxDistSq = 0;
      int index = -1;
      final ax = points[first].latitude;
      final ay = points[first].longitude;
      final bx = points[last].latitude;
      final by = points[last].longitude;
      final dx = bx - ax;
      final dy = by - ay;
      final segLenSq = dx * dx + dy * dy;

      for (var i = first + 1; i < last; i++) {
        final double distSq;
        if (segLenSq == 0) {
          final dlat = points[i].latitude - ax;
          final dlng = points[i].longitude - ay;
          distSq = dlat * dlat + dlng * dlng;
        } else {
          var t =
              ((points[i].latitude - ax) * dx + (points[i].longitude - ay) * dy) /
                  segLenSq;
          t = t.clamp(0.0, 1.0);
          final px = ax + t * dx - points[i].latitude;
          final py = ay + t * dy - points[i].longitude;
          distSq = px * px + py * py;
        }
        if (distSq > maxDistSq) {
          maxDistSq = distSq;
          index = i;
        }
      }

      if (index != -1 && maxDistSq > tolSq) {
        keep[index] = true;
        stack.add((first, index));
        stack.add((index, last));
      }
    }

    final out = <LatLng>[];
    for (var i = 0; i < points.length; i++) {
      if (keep[i]) out.add(points[i]);
    }
    return out;
  }
}
