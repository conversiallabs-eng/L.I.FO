import 'dart:math';
import '../../features/route_manifest/domain/models/delivery_stop.dart';
import '../../features/route_manifest/domain/models/package_item.dart';
import '../../features/route_manifest/domain/models/spatial_slot.dart';

class LifoCalculator {
  /// Distância em metros entre dois pontos geográficos (Fórmula de Haversine).
  static double calculateDistanceMeters(
    double lat1,
    double lon1,
    double lat2,
    double lon2,
  ) {
    const double earthRadius = 6371000; // Raio da Terra em metros
    final double dLat = _degToRad(lat2 - lat1);
    final double dLon = _degToRad(lon2 - lon1);

    final double a = sin(dLat / 2) * sin(dLat / 2) +
        cos(_degToRad(lat1)) *
            cos(_degToRad(lat2)) *
            sin(dLon / 2) *
            sin(dLon / 2);
    final double c = 2 * atan2(sqrt(a), sqrt(1 - a));
    return earthRadius * c;
  }

  static double _degToRad(double deg) => deg * (pi / 180.0);

  /// Comprimento total do trajeto em metros.
  static double pathLength(
    List<DeliveryStop> ordered, {
    double? startLat,
    double? startLng,
  }) {
    if (ordered.isEmpty) return 0;
    double total = 0;
    double prevLat = startLat ?? ordered.first.latitude;
    double prevLng = startLng ?? ordered.first.longitude;
    final start = (startLat != null && startLng != null) ? 0 : 1;
    for (int i = start; i < ordered.length; i++) {
      total += calculateDistanceMeters(
        prevLat,
        prevLng,
        ordered[i].latitude,
        ordered[i].longitude,
      );
      prevLat = ordered[i].latitude;
      prevLng = ordered[i].longitude;
    }
    return total;
  }

  /// Ordena as paradas por proximidade estrita (Nearest Neighbor):
  /// - A parada 1 é SEMPRE a mais próxima do ponto de partida (GPS do motorista).
  /// - A parada 2 é a mais próxima da parada 1.
  /// - A parada 3 é a mais próxima da parada 2... e assim por diante.
  static List<DeliveryStop> nearestNeighbor(
    List<DeliveryStop> rawStops, {
    double? startLat,
    double? startLng,
  }) {
    if (rawStops.isEmpty) return [];

    final List<DeliveryStop> unvisited = List.from(rawStops);
    final List<DeliveryStop> ordered = [];

    // O ponto de partida é SEMPRE a localização do usuário quando fornecida
    double currentLat = startLat ?? rawStops.first.latitude;
    double currentLng = startLng ?? rawStops.first.longitude;

    while (unvisited.isNotEmpty) {
      int bestIndex = 0;
      double minDistance = double.infinity;

      for (int i = 0; i < unvisited.length; i++) {
        final dist = calculateDistanceMeters(
          currentLat,
          currentLng,
          unvisited[i].latitude,
          unvisited[i].longitude,
        );
        if (dist < minDistance) {
          minDistance = dist;
          bestIndex = i;
        }
      }

      final nextStop = unvisited.removeAt(bestIndex);
      ordered.add(nextStop);
      currentLat = nextStop.latitude;
      currentLng = nextStop.longitude;
    }

    return ordered;
  }

  /// Refinamento 2-opt para eliminar cruzamentos no trajeto.
  /// Quando [fixFirst] é true ou quando parte do GPS com startLat/Lng,
  /// a primeira parada (mais próxima de onde o motorista está) permanece fixa.
  static List<DeliveryStop> twoOpt(
    List<DeliveryStop> ordered, {
    double? startLat,
    double? startLng,
    bool fixFirst = false,
  }) {
    if (ordered.length < 3) return List.from(ordered);

    List<DeliveryStop> route = List.from(ordered);
    final hasStart = startLat != null && startLng != null;
    final int startIndex = (hasStart && fixFirst) ? 1 : 0;

    bool improved = true;
    int passes = 0;
    while (improved && passes < 40) {
      improved = false;
      passes++;

      for (int i = startIndex; i < route.length - 1; i++) {
        for (int k = i + 1; k < route.length; k++) {
          final double? aLat = (i == 0)
              ? (hasStart ? startLat : null)
              : route[i - 1].latitude;
          final double? aLng = (i == 0)
              ? (hasStart ? startLng : null)
              : route[i - 1].longitude;
          final bLat = route[i].latitude;
          final bLng = route[i].longitude;
          final cLat = route[k].latitude;
          final cLng = route[k].longitude;
          final double? dLat = (k + 1 < route.length)
              ? route[k + 1].latitude
              : null;
          final double? dLng = (k + 1 < route.length)
              ? route[k + 1].longitude
              : null;

          double distBefore = 0;
          double distAfter = 0;

          if (aLat != null && aLng != null) {
            distBefore += calculateDistanceMeters(aLat, aLng, bLat, bLng);
            distAfter += calculateDistanceMeters(aLat, aLng, cLat, cLng);
          }
          if (dLat != null && dLng != null) {
            distBefore += calculateDistanceMeters(cLat, cLng, dLat, dLng);
            distAfter += calculateDistanceMeters(bLat, bLng, dLat, dLng);
          }

          if (distAfter < distBefore - 2.0) {
            final reversed = route
                .getRange(i, k + 1)
                .toList()
                .reversed
                .toList();
            route.replaceRange(i, k + 1, reversed);
            improved = true;
            break;
          }
        }
        if (improved) break;
      }
    }
    return route;
  }

  /// Nearest Neighbor usando matriz de custos.
  static List<int> nearestNeighborWithMatrix(List<List<double>> matrix) {
    final n = matrix.length;
    if (n <= 1) return [0];

    final unvisited = <int>{for (int i = 1; i < n; i++) i};
    final route = <int>[0];
    int current = 0;

    while (unvisited.isNotEmpty) {
      int best = unvisited.first;
      double bestCost = double.infinity;

      for (final candidate in unvisited) {
        final cost = matrix[current][candidate];
        if (cost < bestCost) {
          bestCost = cost;
          best = candidate;
        }
      }

      unvisited.remove(best);
      route.add(best);
      current = best;
    }

    return route;
  }

  /// 2-opt com matriz de custos.
  static List<int> twoOptWithMatrix(
    List<int> route,
    List<List<double>> matrix, {
    bool fixFirst = false,
  }) {
    if (route.length < 4) return List.from(route);

    final result = List<int>.from(route);
    bool improved = true;
    int passes = 0;
    final int startIndex = fixFirst ? 2 : 1;

    while (improved && passes < 60) {
      improved = false;
      passes++;

      for (int i = startIndex; i < result.length - 1; i++) {
        for (int k = i + 1; k < result.length; k++) {
          final before = _matrixRouteCost(result, matrix);
          final candidate = List<int>.from(result);
          final segment = candidate.sublist(i, k + 1).reversed.toList();
          candidate.replaceRange(i, k + 1, segment);

          final after = _matrixRouteCost(candidate, matrix);
          if (after < before - 1.0) {
            result
              ..clear()
              ..addAll(candidate);
            improved = true;
            break;
          }
        }
        if (improved) break;
      }
    }

    return result;
  }

  static double _matrixRouteCost(List<int> route, List<List<double>> matrix) {
    double total = 0;
    for (int i = 1; i < route.length; i++) {
      total += matrix[route[i - 1]][route[i]];
    }
    return total;
  }

  static List<DeliveryStop> optimizeWithMatrix(
    List<DeliveryStop> stops,
    List<List<double>> durationMatrix,
  ) {
    if (stops.isEmpty) return [];
    if (stops.length == 1) return assignSlots(stops);

    final nnRoute = nearestNeighborWithMatrix(durationMatrix);
    final optimizedRoute = twoOptWithMatrix(
      nnRoute,
      durationMatrix,
      fixFirst: false,
    );

    final reordered = <DeliveryStop>[];
    for (int i = 1; i < optimizedRoute.length; i++) {
      reordered.add(stops[optimizedRoute[i] - 1]);
    }

    return assignSlots(reordered);
  }

  /// Atribui slots espaciais LIFO de acordo com a sequência de entrega (1..N).
  /// A Parada 1 descarrega primeiro -> Porta Traseira.
  static List<DeliveryStop> assignSlots(List<DeliveryStop> ordered) {
    final int totalStops = ordered.length;
    final List<DeliveryStop> lifoMappedStops = [];

    for (int i = 0; i < totalStops; i++) {
      final sequence = i + 1;
      final spatialSlot = SpatialSlot.slotForDeliverySequence(
        sequence,
        totalStops,
      );

      final updatedPackages = ordered[i].packages.map((pkg) {
        return pkg.copyWith(spatialSlot: spatialSlot);
      }).toList();

      lifoMappedStops.add(
        ordered[i].copyWith(
          sequenceIndex: sequence,
          spatialSlot: spatialSlot,
          packages: updatedPackages,
        ),
      );
    }

    return lifoMappedStops;
  }

  /// Otimiza a lista de paradas garantindo que a Parada 1 seja a mais próxima
  /// do ponto de partida (GPS do usuário).
  static List<DeliveryStop> optimizeRouteStops(
    List<DeliveryStop> rawStops, {
    double? startLat,
    double? startLng,
  }) {
    if (rawStops.isEmpty) return [];
    if (rawStops.length == 1) {
      return assignSlots(rawStops);
    }

    // Nearest Neighbor:
    // Ponto 0 = GPS do usuário.
    // Parada 1 = a mais próxima do GPS.
    final ordered = nearestNeighbor(
      rawStops,
      startLat: startLat,
      startLng: startLng,
    );

    // Refinamento 2-opt: desembaraça a rota eliminando auto-cruzamentos
    // enquanto mantém a Parada 1 fixada como a mais próxima do entregador.
    final untangled = twoOpt(
      ordered,
      startLat: startLat,
      startLng: startLng,
      fixFirst: startLat != null && startLng != null,
    );

    return assignSlots(untangled);
  }

  static List<PackageItem> getLoadingSequence(List<PackageItem> packages) {
    final list = List<PackageItem>.from(packages);
    list.sort(
      (a, b) =>
          a.spatialSlot.loadingOrder.compareTo(b.spatialSlot.loadingOrder),
    );
    return list;
  }

  static List<PackageItem> getUnloadingSequence(List<PackageItem> packages) {
    final list = List<PackageItem>.from(packages);
    list.sort(
      (a, b) =>
          a.spatialSlot.unloadingOrder.compareTo(b.spatialSlot.unloadingOrder),
    );
    return list;
  }
}
