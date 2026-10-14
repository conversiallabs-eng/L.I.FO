import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import '../../../../core/map/tile_cache.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../route_manifest/domain/models/delivery_stop.dart';
import '../../../route_manifest/presentation/manifest_controller.dart';

class NavigationMapScreen extends ConsumerStatefulWidget {
  const NavigationMapScreen({super.key});

  @override
  ConsumerState<NavigationMapScreen> createState() => _NavigationMapScreenState();
}

class _NavigationMapScreenState extends ConsumerState<NavigationMapScreen> {
  late final MapController _mapController;
  int _activeStopIndex = 0;
  bool _forceNightMode = false;

  @override
  void initState() {
    super.initState();
    _mapController = MapController();
  }

  @override
  void dispose() {
    _mapController.dispose();
    super.dispose();
  }

  void _recenterRoute(List<DeliveryStop> stops) {
    if (stops.isEmpty) return;
    final current = stops[_activeStopIndex.clamp(0, stops.length - 1)];
    _mapController.move(
      LatLng(current.latitude, current.longitude),
      14.5,
    );
  }

  @override
  Widget build(BuildContext context) {
    final manifestState = ref.watch(manifestControllerProvider);
    final isSystemDark = Theme.of(context).brightness == Brightness.dark;
    final isCabinNight = isSystemDark || _forceNightMode;
    final currentVersion = manifestState.currentVersion;
    final stops = currentVersion?.stops ?? [];

    // Fallback coordinates if no stops
    final LatLng defaultCenter = stops.isNotEmpty
        ? LatLng(stops.first.latitude, stops.first.longitude)
        : const LatLng(-23.5505, -46.6333);

    // Rota real: usa polyline OSRM (ruas) quando disponível, fallback linear offline.
    final List<LatLng> fallbackPoints = stops.map((s) => LatLng(s.latitude, s.longitude)).toList();
    final List<LatLng> routePoints = manifestState.roadPolyline.isNotEmpty
        ? manifestState.roadPolyline
        : fallbackPoints;

    final DeliveryStop? activeStop = stops.isNotEmpty
        ? stops[_activeStopIndex.clamp(0, stops.length - 1)]
        : null;

    final retina = RetinaMode.isHighDensity(context);
    final tileProvider = TileCache.instance.provider;

    return Scaffold(
      body: Stack(
        children: [
          // Minimalist Map Viewport (repaint isolado do resto da tela)
          RepaintBoundary(
            child: FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: defaultCenter,
              initialZoom: 13.0,
              minZoom: 5.0,
              maxZoom: 18.0,
              backgroundColor: isCabinNight
                  ? AppColors.carbonBackground
                  : AppColors.lightBackground,
            ),
            children: [
              // Tiles sem API key + retina + cache em disco:
              // noturno = ESRI Dark Gray, claro = ESRI Street Map (colorido).
              if (isCabinNight) ...[
                TileLayer(
                  urlTemplate:
                      'https://server.arcgisonline.com/ArcGIS/rest/services/Canvas/World_Dark_Gray_Base/MapServer/tile/{z}/{y}/{x}',
                  userAgentPackageName: 'com.lifo.app',
                  tileProvider: tileProvider,
                  retinaMode: retina,
                  maxZoom: 19,
                  maxNativeZoom: 16,
                  keepBuffer: 4,
                  panBuffer: 2,
                  tileDisplay: const TileDisplay.fadeIn(),
                ),
                TileLayer(
                  urlTemplate:
                      'https://server.arcgisonline.com/ArcGIS/rest/services/Canvas/World_Dark_Gray_Reference/MapServer/tile/{z}/{y}/{x}',
                  userAgentPackageName: 'com.lifo.app',
                  tileProvider: tileProvider,
                  retinaMode: retina,
                  maxZoom: 19,
                  maxNativeZoom: 16,
                  keepBuffer: 4,
                  panBuffer: 2,
                  tileDisplay: const TileDisplay.fadeIn(),
                ),
              ] else ...[
                TileLayer(
                  urlTemplate:
                      'https://server.arcgisonline.com/ArcGIS/rest/services/World_Street_Map/MapServer/tile/{z}/{y}/{x}',
                  userAgentPackageName: 'com.lifo.app',
                  tileProvider: tileProvider,
                  retinaMode: retina,
                  maxZoom: 19,
                  maxNativeZoom: 19,
                  keepBuffer: 4,
                  panBuffer: 2,
                  tileDisplay: const TileDisplay.fadeIn(),
                ),
              ],

              // Rota estilo Uber: glow + casing branco + núcleo Circuit.
              if (routePoints.length > 1)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: routePoints,
                      strokeWidth: 13.0,
                      color: AppColors.routePolylineGlow.withValues(alpha: 0.30),
                    ),
                    Polyline(
                      points: routePoints,
                      strokeWidth: 8.0,
                      color: isCabinNight
                          ? Colors.white.withValues(alpha: 0.92)
                          : Colors.white,
                    ),
                    // Foreground navigation route
                    Polyline(
                      points: routePoints,
                      strokeWidth: 5.0,
                      color: isCabinNight ? AppColors.routePolylineNight : AppColors.routePolylineDay,
                    ),
                  ],
                ),

              // Vector Markers for Stops
              MarkerLayer(
                markers: stops.asMap().entries.map((entry) {
                  final index = entry.key;
                  final stop = entry.value;
                  final isCurrent = index == _activeStopIndex;
                  final isCompleted = stop.status == StopStatus.completed;

                  return Marker(
                    point: LatLng(stop.latitude, stop.longitude),
                    width: isCurrent ? 44.0 : 34.0,
                    height: isCurrent ? 44.0 : 34.0,
                    child: GestureDetector(
                      onTap: () {
                        setState(() {
                          _activeStopIndex = index;
                        });
                        _mapController.move(LatLng(stop.latitude, stop.longitude), 15.0);
                      },
                      child: _buildVectorMarker(
                        sequence: stop.sequenceIndex,
                        isCurrent: isCurrent,
                        isCompleted: isCompleted,
                        slotColor: stop.spatialSlot.visualColor,
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
            ),
          ),

          // Top HUD Bar: Night mode toggle & Recenter
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: (isCabinNight ? Colors.black : Colors.white).withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isCabinNight ? Colors.white24 : Colors.black12,
                      ),
                    ),
                    child: Text(
                      isCabinNight ? 'MODO CABINE NOTURNO' : 'MODO CABINE DIURNO',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.8,
                        color: isCabinNight ? Colors.white : Colors.black,
                      ),
                    ),
                  ),
                  const Spacer(),
                  // Contrast mode toggle
                  CircleAvatar(
                    backgroundColor: (isCabinNight ? AppColors.darkSurface : Colors.white).withValues(alpha: 0.9),
                    child: IconButton(
                      tooltip: 'Alternar Contraste Cabine',
                      icon: Icon(
                        _forceNightMode ? Icons.nightlight_round : Icons.wb_sunny_outlined,
                        color: isCabinNight ? AppColors.accentAmber : Colors.black,
                        size: 20,
                      ),
                      onPressed: () {
                        setState(() {
                          _forceNightMode = !_forceNightMode;
                        });
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Recenter button
                  CircleAvatar(
                    backgroundColor: (isCabinNight ? AppColors.darkSurface : Colors.white).withValues(alpha: 0.9),
                    child: IconButton(
                      tooltip: 'Centralizar Rota',
                      icon: Icon(
                        Icons.my_location,
                        color: isCabinNight ? Colors.white : Colors.black,
                        size: 20,
                      ),
                      onPressed: () => _recenterRoute(stops),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Bottom GPS Turn / Next Delivery HUD
          if (activeStop != null)
            Positioned(
              left: 16,
              right: 16,
              bottom: 16,
              child: SafeArea(
                child: _buildNavigationHUD(
                  stop: activeStop,
                  isDark: isCabinNight,
                  totalStops: stops.length,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildVectorMarker({
    required int sequence,
    required bool isCurrent,
    required bool isCompleted,
    required Color slotColor,
  }) {
    Color bgColor = slotColor;
    if (isCompleted) {
      bgColor = AppColors.routeCompleted;
    } else if (isCurrent) {
      bgColor = AppColors.markerCurrent;
    }

    return Container(
      decoration: BoxDecoration(
        color: bgColor,
        shape: BoxShape.circle,
        border: Border.all(
          color: Colors.white,
          width: isCurrent ? 3.0 : 2.0,
        ),
        boxShadow: const [
          BoxShadow(
            color: Colors.black45,
            blurRadius: 6,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: Center(
        child: Text(
          '$sequence',
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w900,
            fontSize: isCurrent ? 16 : 13,
          ),
        ),
      ),
    );
  }

  Widget _buildNavigationHUD({
    required DeliveryStop stop,
    required bool isDark,
    required int totalStops,
  }) {
    final slot = stop.spatialSlot;
    final isCompleted = stop.status == StopStatus.completed;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
          width: 1.5,
        ),
        boxShadow: const [
          BoxShadow(
            color: Colors.black38,
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: isCompleted
                      ? AppColors.statusSuccess
                      : (isDark ? AppColors.primaryBlueLight : AppColors.primaryBlue),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  isCompleted ? 'ENTREGA CONCLUIDA' : 'PROXIMA PARADA #${stop.sequenceIndex} DE $totalStops',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
              const Spacer(),
              // Spatial slot badge
              Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(color: slot.visualColor, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    slot.label.toUpperCase(),
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: slot.visualColor,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            stop.recipientName,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            stop.address,
            style: TextStyle(
              fontSize: 13,
              color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () {
                    if (_activeStopIndex > 0) {
                      setState(() {
                        _activeStopIndex--;
                      });
                    }
                  },
                  child: const Text('Anterior', style: TextStyle(fontSize: 12)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: ElevatedButton.icon(
                  onPressed: () {
                    final nextStatus = isCompleted ? StopStatus.pending : StopStatus.completed;
                    ref.read(manifestControllerProvider.notifier).updateStopStatus(stop.id, nextStatus);
                    if (!isCompleted && _activeStopIndex < totalStops - 1) {
                      setState(() {
                        _activeStopIndex++;
                      });
                    }
                  },
                  icon: Icon(isCompleted ? Icons.undo : Icons.check_circle_outline, size: 16),
                  label: Text(isCompleted ? 'Reabrir Parada' : 'Confirmar Entrega', style: const TextStyle(fontSize: 12)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: () {
                    if (_activeStopIndex < totalStops - 1) {
                      setState(() {
                        _activeStopIndex++;
                      });
                    }
                  },
                  child: const Text('Proxima', style: TextStyle(fontSize: 12)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
