import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import '../../features/route_manifest/domain/models/delivery_stop.dart';
import '../models/route_step.dart';
import '../utils/lifo_calculator.dart';

class RoutingResult {
  final List<DeliveryStop> stops;
  final List<LatLng> polylinePoints;
  final bool isOnline;
  final double totalDistanceMeters;
  final double totalDurationSeconds;
  final List<double> legDurationsSeconds;

  const RoutingResult({
    required this.stops,
    required this.polylinePoints,
    required this.isOnline,
    required this.totalDistanceMeters,
    required this.totalDurationSeconds,
    this.legDurationsSeconds = const [],
  });

  /// Offsets de chegada em segundos acumulados por parada.
  static List<double> arrivalOffsets({
    required List<double> legDurations,
    required int stopCount,
    required bool hasStart,
  }) {
    if (stopCount == 0) return [];
    if (legDurations.isEmpty) return List.filled(stopCount, 0);
    final offsets = <double>[];
    double acc = 0;
    for (int j = 0; j < stopCount; j++) {
      final legIndex = hasStart ? j : j - 1;
      if (legIndex >= 0 && legIndex < legDurations.length) {
        acc += legDurations[legIndex];
      }
      offsets.add(acc);
    }
    return offsets;
  }
}

class HybridRoutingService {
  static const _osrmServers = [
    'https://router.project-osrm.org',
    'https://routing.openstreetmap.de/routed-car',
  ];

  /// Otimiza a sequência das paradas e calcula o traçado da rota.
  /// - Ponto de partida: Sempre a localização do usuário (startLat, startLng).
  /// - Parada 1: Sempre a mais próxima da localização do usuário.
  /// - A polilinha traçada começa exatamente na localização do usuário e vai até a Parada 1.
  Future<RoutingResult> optimizeAndRoute({
    required List<DeliveryStop> rawStops,
    double? startLat,
    double? startLng,
  }) async {
    if (rawStops.isEmpty) {
      return const RoutingResult(
        stops: [],
        polylinePoints: [],
        isOnline: false,
        totalDistanceMeters: 0,
        totalDurationSeconds: 0,
        legDurationsSeconds: [],
      );
    }

    // Garante que o ponto de partida é SEMPRE o GPS do usuário
    if (startLat == null || startLng == null) {
      try {
        final pos = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.medium,
            timeLimit: Duration(seconds: 4),
          ),
        );
        startLat = pos.latitude;
        startLng = pos.longitude;
      } catch (_) {
        try {
          final last = await Geolocator.getLastKnownPosition();
          if (last != null) {
            startLat = last.latitude;
            startLng = last.longitude;
          }
        } catch (_) {}
      }
    }

    // 1. Tenta otimização viária real (OSRM Trip API - respeita a SC-401, mãos de direção e proximidade real por asfalto)
    if (startLat != null && startLng != null && rawStops.length <= 98) {
      final tripResult = await _optimizeWithOsrmTrip(
        rawStops: rawStops,
        startLat: startLat,
        startLng: startLng,
      );
      if (tripResult != null && tripResult.stops.isNotEmpty) {
        return tripResult;
      }
    }

    // 2. Fallback por Nearest Neighbor (se offline)
    final orderedStops = LifoCalculator.optimizeRouteStops(
      rawStops,
      startLat: startLat,
      startLng: startLng,
    );

    // 2. Traça a rota viária pelas ruas (OSRM), começando na posição do usuário
    try {
      final geom = await _fetchRouteGeometry(
        stops: orderedStops,
        startLat: startLat,
        startLng: startLng,
      );
      if (geom != null && geom.points.isNotEmpty) {
        return RoutingResult(
          stops: orderedStops,
          polylinePoints: geom.points,
          isOnline: true,
          totalDistanceMeters: geom.distance,
          totalDurationSeconds: geom.duration,
          legDurationsSeconds: geom.legs,
        );
      }
    } catch (e) {
      debugPrint('Erro ao buscar geometria OSRM: $e');
    }

    // 3. Fallback offline: polilinha conectando o ponto de partida à Parada 1 e seguintes
    final List<LatLng> fallbackPolyline = [];
    if (startLat != null && startLng != null) {
      fallbackPolyline.add(LatLng(startLat, startLng));
    }
    for (final stop in orderedStops) {
      fallbackPolyline.add(LatLng(stop.latitude, stop.longitude));
    }

    return RoutingResult(
      stops: orderedStops,
      polylinePoints: fallbackPolyline,
      isOnline: false,
      totalDistanceMeters: 0,
      totalDurationSeconds: 0,
      legDurationsSeconds: const [],
    );
  }

  /// Busca o traçado viário para paradas que já possuem uma ordem definida,
  /// mantendo o traçado iniciando na posição do usuário.
  Future<RoutingResult> fetchGeometryOnly({
    required List<DeliveryStop> stops,
    double? startLat,
    double? startLng,
  }) async {
    if (stops.isEmpty) {
      return const RoutingResult(
        stops: [],
        polylinePoints: [],
        isOnline: false,
        totalDistanceMeters: 0,
        totalDurationSeconds: 0,
        legDurationsSeconds: [],
      );
    }

    try {
      final geom = await _fetchRouteGeometry(
        stops: stops,
        startLat: startLat,
        startLng: startLng,
      );
      if (geom != null && geom.points.isNotEmpty) {
        return RoutingResult(
          stops: stops,
          polylinePoints: geom.points,
          isOnline: true,
          totalDistanceMeters: geom.distance,
          totalDurationSeconds: geom.duration,
          legDurationsSeconds: geom.legs,
        );
      }
    } catch (_) {}

    final List<LatLng> fallback = [];
    if (startLat != null && startLng != null) {
      fallback.add(LatLng(startLat, startLng));
    }
    for (final s in stops) {
      fallback.add(LatLng(s.latitude, s.longitude));
    }

    return RoutingResult(
      stops: stops,
      polylinePoints: fallback,
      isOnline: false,
      totalDistanceMeters: 0,
      totalDurationSeconds: 0,
      legDurationsSeconds: const [],
    );
  }

  /// Trajeto de um ponto a outro (ex: GPS até próxima parada).
  /// Retorna também os steps de manobra do OSRM (gratuito).
  Future<({List<LatLng> points, double distance, double duration, List<RouteStep> steps})?> fetchLegRoute({
    required LatLng from,
    required LatLng to,
  }) async {
    final coords = '${from.longitude},${from.latitude};${to.longitude},${to.latitude}';
    for (final server in _osrmServers) {
      try {
        // steps=true → OSRM devolve turn-by-turn grátis
        final url = '$server/route/v1/driving/$coords?overview=full&geometries=geojson&steps=true';
        final response = await http.get(
          Uri.parse(url),
          headers: {'User-Agent': 'LIFO-Logistics/1.0'},
        ).timeout(const Duration(seconds: 10));

        if (response.statusCode != 200) continue;
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final routes = data['routes'] as List<dynamic>?;
        if (routes == null || routes.isEmpty) continue;
        final first = routes.first as Map<String, dynamic>;
        final rawPoints =
            (first['geometry'] as Map<String, dynamic>?)?['coordinates'] as List<dynamic>?;
        if (rawPoints == null || rawPoints.isEmpty) continue;

        // Parseia steps do primeiro leg
        final steps = _parseOsrmSteps(first);

        return (
          points: [
            for (final p in rawPoints)
              LatLng((p[1] as num).toDouble(), (p[0] as num).toDouble()),
          ],
          distance: (first['distance'] as num?)?.toDouble() ?? 0.0,
          duration: (first['duration'] as num?)?.toDouble() ?? 0.0,
          steps: steps,
        );
      } catch (_) {}
    }
    return null;
  }

  /// Converte os steps OSRM em lista de RouteStep
  List<RouteStep> _parseOsrmSteps(Map<String, dynamic> route) {
    final legs = route['legs'] as List<dynamic>?;
    if (legs == null || legs.isEmpty) return [];
    final rawSteps = (legs.first as Map<String, dynamic>)['steps'] as List<dynamic>?;
    if (rawSteps == null) return [];

    final result = <RouteStep>[];
    for (final raw in rawSteps) {
      final step = raw as Map<String, dynamic>;
      final maneuverMap = step['maneuver'] as Map<String, dynamic>?;
      if (maneuverMap == null) continue;

      final type = maneuverMap['type'] as String? ?? '';
      final modifier = maneuverMap['modifier'] as String? ?? '';
      final exit = maneuverMap['exit'] as int? ?? 0;
      final distance = (step['distance'] as num?)?.toDouble() ?? 0.0;
      // Nome da rua: OSRM devolve em "name" ou "ref"
      final name = (step['name'] as String?) ?? '';
      final ref = (step['ref'] as String?) ?? '';
      final streetName = name.isNotEmpty ? name : (ref.isNotEmpty ? ref : '');

      final maneuver = RouteStep.fromOsrm(type, modifier);

      // Coordenada da manobra (p/ o HUD saber ONDE é a curva/rotatória).
      LatLng? location;
      final loc = maneuverMap['location'] as List<dynamic>?;
      if (loc != null && loc.length >= 2) {
        final lng = (loc[0] as num?)?.toDouble();
        final lat = (loc[1] as num?)?.toDouble();
        if (lng != null && lat != null) {
          location = LatLng(lat, lng);
        }
      }

      // Ignora passos de chegada com distância 0 (último step vazio do OSRM)
      if (maneuver == ManeuverType.arrive && distance < 1) {
        result.add(RouteStep(
          maneuver: maneuver,
          distanceMeters: distance,
          streetName: streetName,
          roundaboutExit: exit,
          location: location,
        ));
        break;
      }

      result.add(RouteStep(
        maneuver: maneuver,
        distanceMeters: distance,
        streetName: streetName,
        roundaboutExit: exit,
        location: location,
      ));
    }
    return result;
  }

  // ---------------------------------------------------------------------------
  // Consulta de geometria no OSRM
  // ---------------------------------------------------------------------------

  /// Distância de RUA na ordem exata dada (p/ o comparativo honesto
  /// "ordem do manifesto x otimizada"). Retorna -1 se offline/sem rota.
  Future<double> roadDistanceForPoints(List<LatLng> points) async {
    if (points.length < 2) return -1;
    try {
      final coords = <String>[
        for (final p in points) '${p.longitude},${p.latitude}',
      ];
      final result = await routeForCoordinates(coords);
      final d = result?.distance ?? 0;
      return d > 0 ? d : -1;
    } catch (_) {
      return -1;
    }
  }

  Future<({List<LatLng> points, double distance, double duration, List<double> legs})?> _fetchRouteGeometry({
    required List<DeliveryStop> stops,
    double? startLat,
    double? startLng,
  }) async {
    final List<String> coordinates = [];

    // O ponto de partida é SEMPRE a localização do usuário (se fornecida)
    if (startLat != null && startLng != null) {
      coordinates.add('$startLng,$startLat');
    }
    for (final stop in stops) {
      coordinates.add('${stop.longitude},${stop.latitude}');
    }

    return routeForCoordinates(coordinates);
  }

  /// Roteiriza coordenadas na ordem dada (com chunks de 25 pontos).
  Future<({List<LatLng> points, double distance, double duration, List<double> legs})?> routeForCoordinates(
    List<String> coordinates,
  ) async {
    if (coordinates.length < 2) return null;

    const int chunkSize = 25;
    final List<LatLng> fullPolyline = [];
    double totalDistance = 0.0;
    double totalDuration = 0.0;
    final List<double> allLegs = [];

    for (int i = 0; i < coordinates.length - 1; i += chunkSize - 1) {
      final end = (i + chunkSize < coordinates.length) ? i + chunkSize : coordinates.length;
      final segmentCoords = coordinates.sublist(i, end);
      if (segmentCoords.length < 2) break;

      final chunkResult = await _queryOsrmChunk(segmentCoords);
      if (chunkResult != null) {
        if (fullPolyline.isNotEmpty && chunkResult.points.isNotEmpty) {
          fullPolyline.addAll(chunkResult.points.skip(1));
        } else {
          fullPolyline.addAll(chunkResult.points);
        }
        totalDistance += chunkResult.distance;
        totalDuration += chunkResult.duration;
        allLegs.addAll(chunkResult.legs);
      } else {
        for (int k = (fullPolyline.isEmpty ? 0 : 1); k < segmentCoords.length; k++) {
          final parts = segmentCoords[k].split(',');
          fullPolyline.add(LatLng(double.parse(parts[1]), double.parse(parts[0])));
        }
      }
    }

    if (fullPolyline.isEmpty) return null;
    return (points: fullPolyline, distance: totalDistance, duration: totalDuration, legs: allLegs);
  }

  Future<({List<LatLng> points, double distance, double duration, List<double> legs})?> _queryOsrmChunk(
    List<String> coords,
  ) async {
    final coordString = coords.join(';');

    for (final server in _osrmServers) {
      try {
        final url = '$server/route/v1/driving/$coordString?overview=full&geometries=geojson';
        final response = await http.get(
          Uri.parse(url),
          headers: {'User-Agent': 'LIFO-Logistics/1.0'},
        ).timeout(const Duration(seconds: 10));

        if (response.statusCode == 200) {
          final Map<String, dynamic> data = jsonDecode(response.body) as Map<String, dynamic>;
          final routes = data['routes'] as List<dynamic>?;
          if (routes != null && routes.isNotEmpty) {
            final firstRoute = routes.first as Map<String, dynamic>;
            final geometry = firstRoute['geometry'] as Map<String, dynamic>?;
            final rawPoints = geometry?['coordinates'] as List<dynamic>?;
            if (rawPoints != null) {
              final pts = <LatLng>[];
              for (final p in rawPoints) {
                pts.add(LatLng((p[1] as num).toDouble(), (p[0] as num).toDouble()));
              }
              final distance = (firstRoute['distance'] as num?)?.toDouble() ?? 0.0;
              final duration = (firstRoute['duration'] as num?)?.toDouble() ?? 0.0;
              final legs = <double>[];
              final rawLegs = firstRoute['legs'] as List<dynamic>?;
              if (rawLegs != null) {
                for (final leg in rawLegs) {
                  legs.add(((leg as Map<String, dynamic>)['duration'] as num?)?.toDouble() ?? 0.0);
                }
              }
              return (points: pts, distance: distance, duration: duration, legs: legs);
            }
          }
        }
      } catch (_) {}
    }
    return null;
  }

  Future<RoutingResult?> _optimizeWithOsrmTrip({
    required List<DeliveryStop> rawStops,
    required double startLat,
    required double startLng,
  }) async {
    final coords = <String>[
      '$startLng,$startLat',
      for (final s in rawStops) '${s.longitude},${s.latitude}',
    ];
    final coordsString = coords.join(';');

    for (final server in _osrmServers) {
      try {
        final url = '$server/trip/v1/driving/$coordsString?source=first&roundtrip=false&geometries=geojson&overview=full';
        final response = await http.get(
          Uri.parse(url),
          headers: {'User-Agent': 'LIFO-Logistics/1.0'},
        ).timeout(const Duration(seconds: 15));

        if (response.statusCode != 200) continue;
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        if (data['code'] != 'Ok') continue;

        final waypoints = data['waypoints'] as List<dynamic>?;
        final trips = data['trips'] as List<dynamic>?;
        if (waypoints == null || waypoints.length != coords.length) continue;
        if (trips == null || trips.isEmpty) continue;

        final firstTrip = trips.first as Map<String, dynamic>;

        // Mapeia cada parada (índice 1..N) para seu índice de visita no trip
        // waypoints[i]['waypoint_index'] é a ordem de visita (0 = partida GPS, 1..N = sequência de entrega)
        final indexedStops = <({int visitOrder, DeliveryStop stop})>[];
        for (int i = 0; i < rawStops.length; i++) {
          final wp = waypoints[i + 1] as Map<String, dynamic>;
          final visitOrder = (wp['waypoint_index'] as num).toInt();
          indexedStops.add((visitOrder: visitOrder, stop: rawStops[i]));
        }

        indexedStops.sort((a, b) => a.visitOrder.compareTo(b.visitOrder));
        final orderedStops = indexedStops.map((e) => e.stop).toList();
        final lifoStops = LifoCalculator.assignSlots(orderedStops);

        // Extrai polyline da rota viária real
        final geometry = firstTrip['geometry'] as Map<String, dynamic>?;
        final rawCoords = geometry?['coordinates'] as List<dynamic>?;
        final polyline = <LatLng>[];
        if (rawCoords != null) {
          for (final c in rawCoords) {
            polyline.add(LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()));
          }
        }

        final distance = (firstTrip['distance'] as num?)?.toDouble() ?? 0.0;
        final duration = (firstTrip['duration'] as num?)?.toDouble() ?? 0.0;
        final legs = <double>[];
        final rawLegs = firstTrip['legs'] as List<dynamic>?;
        if (rawLegs != null) {
          for (final leg in rawLegs) {
            legs.add(((leg as Map<String, dynamic>)['duration'] as num?)?.toDouble() ?? 0.0);
          }
        }

        debugPrint(
          'LIFO OSRM Trip: sucesso com ${lifoStops.length} paradas, '
          '${polyline.length} pontos viários, distance=${(distance / 1000).toStringAsFixed(1)}km',
        );

        return RoutingResult(
          stops: lifoStops,
          polylinePoints: polyline,
          isOnline: true,
          totalDistanceMeters: distance,
          totalDurationSeconds: duration,
          legDurationsSeconds: legs,
        );
      } catch (e) {
        debugPrint('OSRM Trip falhou em $server: $e');
      }
    }
    return null;
  }
}
