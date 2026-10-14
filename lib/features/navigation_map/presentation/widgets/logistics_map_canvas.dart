import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../../../../core/map/tile_cache.dart';
import '../../../../core/theme/app_colors.dart';

class MapCanvasMarker {
  final int sequenceIndex;
  final LatLng position;
  final bool isSelected;
  final bool isCompleted;
  final bool isFailed;
  final Color? slotColor;

  const MapCanvasMarker({
    required this.sequenceIndex,
    required this.position,
    this.isSelected = false,
    this.isCompleted = false,
    this.isFailed = false,
    this.slotColor,
  });
}

class LogisticsMapCanvas extends StatelessWidget {
  final MapController? mapController;
  final LatLng initialCenter;
  final double initialZoom;
  final List<MapCanvasMarker> markers;
  final List<LatLng> routePolyline;
  final bool isSatellite;
  final bool isDark;
  final LatLng? currentLocationPin;
  final double? currentLocationAccuracy;
  final double? headingDegrees;
  final bool isNavigating;
  final void Function(int sequenceIndex)? onMarkerTap;
  final VoidCallback? onMapReady;
  final VoidCallback? onUserInteraction;

  const LogisticsMapCanvas({
    super.key,
    this.mapController,
    required this.initialCenter,
    this.initialZoom = 13.5,
    this.markers = const [],
    this.routePolyline = const [],
    this.isSatellite = false,
    this.isDark = true,
    this.currentLocationPin,
    this.currentLocationAccuracy,
    this.headingDegrees,
    this.isNavigating = false,
    this.onMarkerTap,
    this.onMapReady,
    this.onUserInteraction,
  });

  // Tiles 100% sem API key (CARTO passou a exigir key desde 25/09/2026).
  // - Light: ESRI World Street Map (COLORIDO estilo iFood/Google: ruas,
  //   parques, água e labels vibrantes — inclui rótulos, sem overlay extra).
  // - Dark: ESRI Canvas Dark Gray Base + Reference (grafite, combina com a UI).
  // - Satellite: ESRI World Imagery.
  static const String _esriStreets =
      'https://server.arcgisonline.com/ArcGIS/rest/services/World_Street_Map/MapServer/tile/{z}/{y}/{x}';
  static const String _esriDarkBase =
      'https://server.arcgisonline.com/ArcGIS/rest/services/Canvas/World_Dark_Gray_Base/MapServer/tile/{z}/{y}/{x}';
  static const String _esriDarkRef =
      'https://server.arcgisonline.com/ArcGIS/rest/services/Canvas/World_Dark_Gray_Reference/MapServer/tile/{z}/{y}/{x}';
  static const String _satelliteTile =
      'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';

  /// Calcula bounds que englobam rota + GPS para `fitCamera`.
  static LatLngBounds? boundsForPoints(List<LatLng> points) {
    if (points.isEmpty) return null;
    double minLat = points.first.latitude;
    double maxLat = points.first.latitude;
    double minLng = points.first.longitude;
    double maxLng = points.first.longitude;
    for (final p in points) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    // Evita bounds degenerados (1 ponto só) expandindo minimamente.
    if (minLat == maxLat && minLng == maxLng) {
      const d = 0.005;
      return LatLngBounds(
        LatLng(minLat - d, minLng - d),
        LatLng(maxLat + d, maxLng + d),
      );
    }
    return LatLngBounds(LatLng(minLat, minLng), LatLng(maxLat, maxLng));
  }

  /// Enquadramento determinístico (centro + zoom) a partir dos pontos e do
  /// tamanho visível do mapa. Não depende de padding frágil nem lança
  /// exceção — usado no lugar de `fitCamera` após importar/otimizar.
  static ({LatLng center, double zoom}) frameForPoints({
    required List<LatLng> points,
    required double viewportWidth,
    required double viewportHeight,
  }) {
    final bounds = boundsForPoints(points)!;
    final center = LatLng(
      (bounds.north + bounds.south) / 2,
      (bounds.east + bounds.west) / 2,
    );
    final dLat = max((bounds.north - bounds.south).abs(), 0.004);
    final dLng = max((bounds.east - bounds.west).abs(), 0.004);
    final w = max(viewportWidth - 96, 60.0);
    final h = max(viewportHeight - 96, 60.0);
    final zoomLng = log(w * 360 / (256 * dLng)) / ln2;
    final zoomLat = log(h * 170 / (256 * dLat)) / ln2;
    final zoom = (min(zoomLng, zoomLat) - 0.3).clamp(3.0, 16.0).toDouble();
    return (center: center, zoom: zoom);
  }

  static int _closestPointIndex(
    List<LatLng> polyline,
    LatLng target,
    int start,
    int end,
  ) {
    if (polyline.isEmpty) return 0;
    final clampEnd = min(end, polyline.length);
    final clampStart = max(0, min(start, clampEnd - 1));

    int bestIdx = clampStart;
    double minDistance = double.infinity;
    final tLat = target.latitude;
    final tLng = target.longitude;

    for (int i = clampStart; i < clampEnd; i++) {
      final p = polyline[i];
      final dLat = p.latitude - tLat;
      final dLng = p.longitude - tLng;
      final distSq = dLat * dLat + dLng * dLng;
      if (distSq < minDistance) {
        minDistance = distSq;
        bestIdx = i;
      }
    }
    return bestIdx;
  }

  static int _findSplitIndex(
    List<LatLng> polyline,
    List<MapCanvasMarker> markers,
    MapCanvasMarker target,
  ) {
    if (polyline.length < 2) return polyline.length;

    final targetIndex = markers.indexOf(target);
    if (targetIndex == -1) {
      return _closestPointIndex(polyline, target.position, 0, polyline.length);
    }

    int searchStart = 0;
    int currentSplit = 0;
    for (int s = 0; s <= targetIndex; s++) {
      final stopPos = markers[s].position;
      final bestIdx = _closestPointIndex(
        polyline,
        stopPos,
        searchStart,
        polyline.length,
      );
      currentSplit = bestIdx;
      searchStart = max(0, bestIdx - 5);
    }
    return currentSplit;
  }

  @override
  Widget build(BuildContext context) {
    final canvasBg = isDark ? AppColors.carbonBackground : AppColors.lightBackground;

    // Segmentação da rota estilo Circuit:
    // 1. nextLeg: do ponto de partida até a próxima parada -> pintada viva, casing e glow
    // 2. remainingLeg: da próxima parada até as subsequentes -> rota mais fraquinha
    List<LatLng> nextLeg = const [];
    List<LatLng> remainingLeg = const [];

    if (routePolyline.length > 1) {
      MapCanvasMarker? activeMarker;
      final selectedIdx = markers.indexWhere((m) => m.isSelected);
      if (selectedIdx != -1) {
        activeMarker = markers[selectedIdx];
      } else {
        final pendingIdx = markers.indexWhere((m) => !m.isCompleted && !m.isFailed);
        if (pendingIdx != -1) {
          activeMarker = markers[pendingIdx];
        } else if (markers.isNotEmpty) {
          activeMarker = markers.first;
        }
      }

      if (activeMarker != null) {
        final splitIdx = _findSplitIndex(routePolyline, markers, activeMarker);
        if (splitIdx > 0 && splitIdx < routePolyline.length - 1) {
          nextLeg = routePolyline.sublist(0, splitIdx + 1);
          remainingLeg = routePolyline.sublist(splitIdx);
        } else {
          nextLeg = routePolyline;
          remainingLeg = const [];
        }
      } else {
        nextLeg = routePolyline;
        remainingLeg = const [];
      }
    }

    // Retina simulada SÓ no satélite (foto não tem rótulo: fica nítida
    // sem efeito colateral). Nas camadas com nome de rua ela encolhe os
    // rótulos à metade e quadruplica os downloads no pinch — por isso fica
    // desligada aqui: rótulo legível + zoom leve. Nitidez total + rótulos
    // normais ao mesmo tempo só com vetor (Fase 2).
    final retina = RetinaMode.isHighDensity(context);
    final tileProvider = TileCache.instance.provider;

    return Stack(
      children: [
        Container(
          color: canvasBg,
          // Isola o repaint do mapa: o GPS atualiza a tela toda a cada fix,
          // mas os tiles/marcadores só repintam quando mudam de verdade.
          child: RepaintBoundary(
            child: FlutterMap(
            mapController: mapController,
            options: MapOptions(
              initialCenter: initialCenter,
              initialZoom: initialZoom,
              minZoom: 4.0,
              // 18: acima disso o retina simulado não carrega nada (tela cinza).
              maxZoom: 18.0,
              backgroundColor: canvasBg,
              onMapReady: onMapReady,
              onMapEvent: (event) {
                // Qualquer gesto manual (arrastar, zoom pinch, scroll) interrompe o follow
                if (event.source != MapEventSource.mapController &&
                    event.source != MapEventSource.fitCamera &&
                    event.source != MapEventSource.nonRotatedSizeChange) {
                  onUserInteraction?.call();
                }
              },
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all,
              ),
            ),
            children: [
              if (isSatellite)
                TileLayer(
                  urlTemplate: _satelliteTile,
                  userAgentPackageName: 'com.lifo.app',
                  tileProvider: tileProvider,
                  retinaMode: retina,
                  maxZoom: 19,
                  maxNativeZoom: 18,
                  keepBuffer: 4,
                  panBuffer: 2,
                  tileDisplay: const TileDisplay.fadeIn(),
                  errorTileCallback: (tile, error, stackTrace) {},
                )
              else if (isDark) ...[
                TileLayer(
                  urlTemplate: _esriDarkBase,
                  userAgentPackageName: 'com.lifo.app',
                  tileProvider: tileProvider,
                  retinaMode: false,
                  maxZoom: 18,
                  maxNativeZoom: 16,
                  keepBuffer: 4,
                  panBuffer: 2,
                  tileDisplay: const TileDisplay.fadeIn(),
                  errorTileCallback: (tile, error, stackTrace) {},
                ),
                TileLayer(
                  urlTemplate: _esriDarkRef,
                  userAgentPackageName: 'com.lifo.app',
                  tileProvider: tileProvider,
                  retinaMode: false,
                  maxZoom: 18,
                  maxNativeZoom: 16,
                  keepBuffer: 4,
                  panBuffer: 2,
                  tileDisplay: const TileDisplay.fadeIn(),
                  errorTileCallback: (tile, error, stackTrace) {},
                ),
              ] else ...[
                // Rua colorida (1 camada só: rótulos já vêm no tile).
                TileLayer(
                  urlTemplate: _esriStreets,
                  userAgentPackageName: 'com.lifo.app',
                  tileProvider: tileProvider,
                  retinaMode: false,
                  maxZoom: 18,
                  maxNativeZoom: 19,
                  keepBuffer: 4,
                  panBuffer: 2,
                  tileDisplay: const TileDisplay.fadeIn(),
                  errorTileCallback: (tile, error, stackTrace) {},
                ),
              ],

              // 1. ROTA RESTANTE (paradas futuras): mais fraquinha, suave e translúcida
              if (remainingLeg.length > 1)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: remainingLeg,
                      strokeWidth: 4.5,
                      color: isDark
                          ? Colors.black.withValues(alpha: 0.20)
                          : Colors.white.withValues(alpha: 0.50),
                    ),
                    Polyline(
                      points: remainingLeg,
                      strokeWidth: 3.0,
                      color: isDark
                          ? const Color(0xFF60A5FA).withValues(alpha: 0.38)
                          : const Color(0xFF2563EB).withValues(alpha: 0.28),
                    ),
                  ],
                ),

              // 2. ROTA ATÉ A PRÓXIMA PARADA: pintada viva, casing claro e glow (estilo Circuit)
              if (nextLeg.length > 1)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: nextLeg,
                      strokeWidth: 12.0,
                      color: AppColors.routePolylineGlow.withValues(alpha: 0.32),
                    ),
                    Polyline(
                      points: nextLeg,
                      strokeWidth: 7.0,
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.95)
                          : Colors.white,
                    ),
                    Polyline(
                      points: nextLeg,
                      strokeWidth: 4.5,
                      color: AppColors.routePolyline,
                    ),
                  ],
                ),



              // Paradas compactas estilo Circuit (rotate: true mantém os números na vertical legíveis)
              MarkerLayer(
                rotate: true,
                markers: markers.map((item) {
                  final isTriple = item.sequenceIndex >= 100;
                  final double tapWidth = item.isSelected
                      ? (isTriple ? 48.0 : 42.0)
                      : (isTriple ? 40.0 : 34.0);
                  final double tapHeight = item.isSelected ? 32.0 : 28.0;

                  return Marker(
                    point: item.position,
                    width: tapWidth,
                    height: tapHeight,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => onMarkerTap?.call(item.sequenceIndex),
                      child: Center(
                        child: _buildStopMarker(item),
                      ),
                    ),
                  );
                }).toList(),
              ),

              // GPS atual
              if (currentLocationPin != null)
                MarkerLayer(
                  markers: [
                    Marker(
                      point: currentLocationPin!,
                      width: 64,
                      height: 64,
                      child: _buildLocationPin(),
                    ),
                  ],
                ),
            ],
            ),
            ),
        ),

        // Atribuição OSM/Esri (exigida por licença)
        Positioned(
          right: 8,
          bottom: 8,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              isSatellite
                  ? '© Esri, Maxar, Earthstar Geographics'
                  : '© Esri, HERE, Garmin, © OpenStreetMap',
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 9,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStopMarker(MapCanvasMarker item) {
    final Color slotAccent = item.slotColor ?? AppColors.circuitBlueGlow;
    final isTriple = item.sequenceIndex >= 100;

    final Color bg;
    final Color borderColor;
    final Color textColor;
    final Color shadowColor;

    if (item.isFailed) {
      // 1. NÃO ENTREGUE / FALHA: Vermelhinho com badge de 'X'
      bg = const Color(0xFFDC2626);
      borderColor = Colors.white;
      textColor = Colors.white;
      shadowColor = const Color(0xFFDC2626).withValues(alpha: 0.45);
    } else if (item.isCompleted) {
      // 2. ENTREGUE / REALIZADA: Verde com número visível e badge '✓'
      bg = const Color(0xFF16A34A);
      borderColor = Colors.white;
      textColor = Colors.white;
      shadowColor = const Color(0xFF16A34A).withValues(alpha: 0.40);
    } else if (item.isSelected) {
      // 3. PARADA ATUALMENTE SELECIONADA / EM NAVEGAÇÃO: Azul de destaque
      bg = AppColors.circuitBlue;
      borderColor = Colors.white;
      textColor = Colors.white;
      shadowColor = AppColors.circuitBlue.withValues(alpha: 0.50);
    } else {
      // 4. PENDENTE
      if (isDark) {
        bg = const Color(0xFF1E293B);
        borderColor = const Color(0xFF475569);
        textColor = const Color(0xFFF1F5F9);
      } else {
        bg = Colors.white;
        borderColor = const Color(0xFFCBD5E1);
        textColor = const Color(0xFF334155);
      }
      shadowColor = Colors.black.withValues(alpha: 0.16);
    }

    final double pillWidth = item.isSelected
        ? (isTriple ? 46.0 : 40.0)
        : (isTriple ? 38.0 : 32.0);
    final double pillHeight = item.isSelected ? 26.0 : 22.0;

    final double fontSize = item.isSelected ? 12.5 : 11.0;
    final FontWeight fontWeight =
        item.isSelected ? FontWeight.w800 : FontWeight.w700;

    return Container(
      width: pillWidth,
      height: pillHeight,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(item.isSelected ? 6 : 5),
        border: Border.all(
          color: borderColor,
          width: item.isSelected ? 1.8 : 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: shadowColor,
            blurRadius: item.isSelected ? 8 : 3,
            spreadRadius: item.isSelected ? 1 : 0,
            offset: Offset(0, item.isSelected ? 2 : 1),
          ),
        ],
      ),
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          // Número da parada (SEMPRE visível, inclusive nas entregues e não entregues!)
          Text(
            '${item.sequenceIndex}',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: textColor,
              fontSize: fontSize,
              fontWeight: fontWeight,
              letterSpacing: -0.3,
              height: 1.0,
            ),
          ),

          // Badge '✓' para entregas realizadas com sucesso
          if (item.isCompleted)
            Positioned(
              right: -3,
              top: -3,
              child: Container(
                width: 11,
                height: 11,
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFF16A34A), width: 1.0),
                  boxShadow: const [
                    BoxShadow(color: Colors.black26, blurRadius: 2, offset: Offset(0, 1)),
                  ],
                ),
                child: const Center(
                  child: Icon(
                    Icons.check,
                    size: 7.5,
                    color: Color(0xFF16A34A),
                  ),
                ),
              ),
            )
          // Badge 'X' para entregas não realizadas (falhas)
          else if (item.isFailed)
            Positioned(
              right: -3,
              top: -3,
              child: Container(
                width: 11,
                height: 11,
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xFFDC2626), width: 1.0),
                  boxShadow: const [
                    BoxShadow(color: Colors.black26, blurRadius: 2, offset: Offset(0, 1)),
                  ],
                ),
                child: const Center(
                  child: Icon(
                    Icons.close,
                    size: 7.5,
                    color: Color(0xFFDC2626),
                  ),
                ),
              ),
            )
          // Ponto sutil do slot LIFO quando não selecionado, nem concluído, nem falhado
          else if (!item.isSelected && item.slotColor != null)
            Positioned(
              right: 2.5,
              top: 2.5,
              child: Container(
                width: 4.0,
                height: 4.0,
                decoration: BoxDecoration(
                  color: slotAccent,
                  shape: BoxShape.circle,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildLocationPin() {
    final heading = headingDegrees;
    final angle = (heading != null) ? (heading * pi / 180.0) : 0.0;

    return Stack(
      alignment: Alignment.center,
      children: [
        // Halo de precisão e pulso
        Container(
          width: isNavigating ? 56 : 50,
          height: isNavigating ? 56 : 50,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.circuitBlue.withValues(alpha: isNavigating ? 0.22 : 0.14),
            border: Border.all(
              color: AppColors.circuitBlueGlow.withValues(alpha: isNavigating ? 0.5 : 0.35),
              width: 1.5,
            ),
          ),
        ),

        // Cursor azul de navegação (estilo Waze/Google Maps Course-Up: aponta sempre para cima da tela)
        if (isNavigating)
          SizedBox(
            width: 38,
            height: 38,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Sombra projetada do cursor
                Transform.translate(
                  offset: const Offset(0, 3),
                  child: const Icon(
                    Icons.navigation_rounded,
                    size: 34,
                    color: Colors.black38,
                  ),
                ),
                // Contorno branco externo
                const Icon(
                  Icons.navigation_rounded,
                  size: 34,
                  color: Colors.white,
                ),
                // Corpo azul primário
                const Icon(
                  Icons.navigation_rounded,
                  size: 28,
                  color: AppColors.circuitBlue,
                ),
                // Ponto central branco
                Container(
                  width: 6,
                  height: 6,
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ),
          )
        else if (heading != null)
          Transform.rotate(
            angle: angle,
            child: const Icon(
              Icons.navigation_rounded,
              color: AppColors.circuitBlueGlow,
              size: 30,
              shadows: [
                Shadow(color: Colors.black54, blurRadius: 6),
              ],
            ),
          )
        else
          Container(
            width: 18,
            height: 18,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.circuitBlueGlow,
              border: Border.all(color: Colors.white, width: 2.5),
              boxShadow: [
                BoxShadow(
                  color: AppColors.circuitBlue.withValues(alpha: 0.8),
                  blurRadius: 10,
                  spreadRadius: 2,
                ),
              ],
            ),
          ),
      ],
    );
  }
}
