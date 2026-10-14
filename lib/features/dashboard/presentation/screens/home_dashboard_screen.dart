import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/lifo_calculator.dart';
import '../../../route_manifest/domain/models/delivery_stop.dart';
import '../../../route_manifest/domain/models/package_item.dart';
import '../../../route_manifest/presentation/manifest_controller.dart';
import '../../../cargo_scanner/presentation/screens/cargo_scanner_screen.dart';
import '../../../vehicle_load/presentation/screens/vehicle_bay_screen.dart';
import '../../../route_manifest/presentation/screens/manifest_versions_screen.dart';
import '../../../route_manifest/presentation/screens/add_stop_sheet.dart';
import '../../../route_manifest/presentation/screens/import_manifest_sheet.dart';
import '../../../route_manifest/presentation/screens/import_success_dialog.dart';
import '../../../navigation_map/presentation/widgets/logistics_map_canvas.dart';
import '../../../../core/services/geocoding_service.dart';
import '../../../../core/services/hybrid_routing_service.dart';
import '../../../../core/services/notification_service.dart';
import '../../../route_manifest/domain/models/manifest_version.dart';
import '../../../auth/presentation/controllers/auth_controller.dart';
import '../../../auth/presentation/screens/create_account_screen.dart';
import '../../../auth/presentation/screens/my_account_screen.dart';
import '../../../auth/presentation/screens/subscription_renewal_screen.dart';
import '../../../auth/presentation/screens/login_screen.dart';
import '../../../auth/presentation/widgets/google_sign_in_button.dart';

class HomeDashboardScreen extends ConsumerStatefulWidget {
  const HomeDashboardScreen({super.key});

  @override
  ConsumerState<HomeDashboardScreen> createState() => _HomeDashboardScreenState();
}

class _HomeDashboardScreenState extends ConsumerState<HomeDashboardScreen>
    with TickerProviderStateMixin {
  late final MapController _mapController;
  final Set<String> _expandedGroupIds = {};
  final Set<String> _collapsedGroupIds = {};
  // Controle livre de altura do card (0.20 colapsado, 0.44 intermediário, 0.94 tela cheia)
  double _sheetExtent = 0.44;
  late final ValueNotifier<double> _sheetExtentNotifier = ValueNotifier<double>(_sheetExtent);
  late final AnimationController _sheetAnimationController;
  Animation<double>? _sheetAnimation;

  void _animateSheetTo(double targetExtent) {
    if (!mounted) return;
    targetExtent = targetExtent.clamp(0.20, 0.94);
    _sheetAnimation = Tween<double>(
      begin: _sheetExtent,
      end: targetExtent,
    ).animate(CurvedAnimation(
      parent: _sheetAnimationController,
      curve: Curves.easeOutCubic,
    ));
    _sheetAnimationController.forward(from: 0.0);
  }

  void _onSheetDragUpdate(DragUpdateDetails details) {
    final screenHeight = MediaQuery.of(context).size.height;
    if (screenHeight <= 0) return;
    final delta = -details.delta.dy / screenHeight;
    _sheetExtent = (_sheetExtent + delta).clamp(0.20, 0.94);
    _sheetExtentNotifier.value = _sheetExtent;
  }

  void _onSheetDragEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    double target = 0.44;
    if (velocity < -250) {
      target = 0.94;
    } else if (velocity > 250) {
      target = _sheetExtent > 0.60 ? 0.44 : 0.20;
    } else {
      if (_sheetExtent > 0.68) {
        target = 0.94;
      } else if (_sheetExtent > 0.32) {
        target = 0.44;
      } else {
        target = 0.20;
      }
    }
    _animateSheetTo(target);
  }

  void _toggleSheetSize() {
    if (_sheetExtent > 0.60) {
      _animateSheetTo(0.44);
    } else {
      _animateSheetTo(0.94);
    }
  }



  int _selectedStopIndex = 0;
  double _cardDragDx = 0.0;
  late final AnimationController _cardDragAnimController;
  Animation<double>? _cardDragAnimation;
  bool _isNavigating = false;
  bool _isSatelliteLayer = false;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  LatLng? _currentLocation;

  void _animateCardDragTo(
    double targetDx, {
    VoidCallback? onComplete,
    Duration duration = const Duration(milliseconds: 200),
    Curve curve = Curves.easeOutCubic,
  }) {
    if (!mounted) return;
    _cardDragAnimation = Tween<double>(
      begin: _cardDragDx,
      end: targetDx,
    ).animate(CurvedAnimation(
      parent: _cardDragAnimController,
      curve: curve,
    ));

    _cardDragAnimController.duration = duration;
    _cardDragAnimController.stop();
    _cardDragAnimController.reset();

    void listener() {
      if (!mounted) return;
      setState(() {
        _cardDragDx = _cardDragAnimation!.value;
      });
    }

    void statusListener(AnimationStatus status) {
      if (status == AnimationStatus.completed) {
        _cardDragAnimController.removeListener(listener);
        _cardDragAnimController.removeStatusListener(statusListener);
        onComplete?.call();
      }
    }

    _cardDragAnimController.addListener(listener);
    _cardDragAnimController.addStatusListener(statusListener);
    _cardDragAnimController.forward();
  }

  void _advanceToNextStop(List<DeliveryStop> stops) {
    final nextIdx = (_selectedStopIndex + 1 < stops.length) ? _selectedStopIndex + 1 : _selectedStopIndex;
    if (nextIdx != _selectedStopIndex) {
      HapticFeedback.lightImpact();
      SystemSound.play(SystemSoundType.click);
      final screenW = MediaQuery.of(context).size.width;
      _animateCardDragTo(-screenW, duration: const Duration(milliseconds: 160), curve: Curves.easeInQuad, onComplete: () {
        if (!mounted) return;
        setState(() {
          _selectedStopIndex = nextIdx;
          _cardDragDx = screenW;
        });
        if (stops[nextIdx].status == StopStatus.pending) {
          ref.read(manifestControllerProvider.notifier).updateStopStatus(
            stops[nextIdx].id,
            StopStatus.inTransit,
          );
        }
        _startInAppNavigation(stops[nextIdx]);
        _animateCardDragTo(0.0, duration: const Duration(milliseconds: 220), curve: Curves.easeOutCubic);
      });
    } else {
      // Já está na última parada -> mola elástica de volta ao centro
      _animateCardDragTo(0.0, duration: const Duration(milliseconds: 240), curve: Curves.easeOutBack);
    }
  }

  void _goToPreviousStop(List<DeliveryStop> stops) {
    final prevIdx = (_selectedStopIndex > 0) ? _selectedStopIndex - 1 : 0;
    if (prevIdx != _selectedStopIndex) {
      HapticFeedback.lightImpact();
      SystemSound.play(SystemSoundType.click);
      final screenW = MediaQuery.of(context).size.width;
      _animateCardDragTo(screenW, duration: const Duration(milliseconds: 160), curve: Curves.easeInQuad, onComplete: () {
        if (!mounted) return;
        setState(() {
          _selectedStopIndex = prevIdx;
          _cardDragDx = -screenW;
        });
        _startInAppNavigation(stops[prevIdx]);
        _animateCardDragTo(0.0, duration: const Duration(milliseconds: 220), curve: Curves.easeOutCubic);
      });
    } else {
      // Já está na primeira parada -> mola elástica de volta ao centro
      _animateCardDragTo(0.0, duration: const Duration(milliseconds: 240), curve: Curves.easeOutBack);
    }
  }
  StreamSubscription<Position>? _positionSub;
  bool _followGps = true;
  bool _didAutoFit = false;
  bool _didAutoReoptimize = false;
  double? _heading;
  double _speedKmh = 0;
  bool _courseUp = false;
  bool _isAnimatingCamera = false;

  // Controlador e rastreamento para auto-scroll da lista de paradas independente do card
  late final ScrollController _routesScrollController;
  int? _lastAutoScrolledIndex;

  void _autoScrollToCurrentStop(int nextIdx, {bool animate = true}) {
    if (!mounted) return;
    if (!_routesScrollController.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _routesScrollController.hasClients) {
          _autoScrollToCurrentStop(nextIdx, animate: animate);
        }
      });
      return;
    }

    try {
      final position = _routesScrollController.position;
      double targetOffset = 0.0;
      if (nextIdx > 0) {
        // Cada item da timeline tem aproximadamente 68px de altura
        targetOffset = (nextIdx * 68.0).clamp(0.0, position.maxScrollExtent);
      }

      if ((position.pixels - targetOffset).abs() > 8) {
        if (animate) {
          _routesScrollController.animateTo(
            targetOffset,
            duration: const Duration(milliseconds: 400),
            curve: Curves.easeOutCubic,
          );
        } else {
          _routesScrollController.jumpTo(targetOffset);
        }
      }
    } catch (e) {
      debugPrint('Auto-scroll routes error: $e');
    }
  }

  // Animação de câmera suave (estilo Google Maps / Circuit)
  late final AnimationController _mapAnimationController;
  VoidCallback? _activeTickListener;
  AnimationStatusListener? _activeStatusListener;
  // Timer de inatividade: após o usuário mexer no mapa, volta com a câmera nas costas do cursor
  Timer? _autoRecenteringTimer;

  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  final GeocodingService _geocoding = GeocodingService();
  final HybridRoutingService _routingService = HybridRoutingService();
  Timer? _searchDebounce;
  List<GeocodingResult> _searchResults = [];
  bool _isSearching = false;
  // Resultado de busca por código de barras
  DeliveryStop? _packageSearchHit;
  PackageItem? _packageSearchHitPkg;

  // Trajeto exclusivo até a próxima parada ativa (estilo Waze/Circuit)
  List<LatLng> _legPolyline = [];
  String? _lastLegTargetStopId;
  LatLng? _lastLegFrom;

  // HUD do topo estilo Waze (exibe parada alvo, endereço e distância real)
  bool _hudVisible = false;        // controla fade-in/out do HUD superior
  Timer? _hudHideTimer;            // timer de auto-ocultar o HUD
  double _lastHudDist = -1;        // última distância que gerou exibição

  @override
  void initState() {
    super.initState();
    _routesScrollController = ScrollController();
    _sheetAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    )..addListener(() {
        if (_sheetAnimation != null) {
          _sheetExtent = _sheetAnimation!.value;
          _sheetExtentNotifier.value = _sheetExtent;
        }
      });
    _mapAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 750),
    );
    _cardDragAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    _mapController = MapController();
    _fetchCurrentLocation();
  }

  /// Animação de transição de câmera suave para posição, zoom e rotação.
  void _animatedMapMove(
    LatLng destLocation,
    double destZoom, {
    double? destRotation,
    int durationMs = 750,
  }) {
    if (!mounted) return;

    if (_activeTickListener != null) {
      _mapAnimationController.removeListener(_activeTickListener!);
      _activeTickListener = null;
    }
    if (_activeStatusListener != null) {
      _mapAnimationController.removeStatusListener(_activeStatusListener!);
      _activeStatusListener = null;
    }

    _mapAnimationController.stop();
    _mapAnimationController.reset();
    _isAnimatingCamera = true;

    final camera = _mapController.camera;
    final startLat = camera.center.latitude;
    final startLng = camera.center.longitude;
    final startZoom = camera.zoom;
    final startRot = camera.rotation;

    double targetRot = startRot;
    if (destRotation != null) {
      double diff = (destRotation - startRot) % 360;
      if (diff > 180) diff -= 360;
      if (diff < -180) diff += 360;
      targetRot = startRot + diff;
    }

    _mapAnimationController.duration = Duration(milliseconds: durationMs);

    void tick() {
      if (!mounted) return;
      final t = Curves.fastOutSlowIn.transform(_mapAnimationController.value);
      final lat = startLat + (destLocation.latitude - startLat) * t;
      final lng = startLng + (destLocation.longitude - startLng) * t;
      final z = startZoom + (destZoom - startZoom) * t;
      final r = ((startRot + (targetRot - startRot) * t) % 360 + 360) % 360;
      _mapController.moveAndRotate(LatLng(lat, lng), z, r);
    }

    void onStatus(AnimationStatus status) {
      if (status == AnimationStatus.completed || status == AnimationStatus.dismissed) {
        if (_activeTickListener != null) {
          _mapAnimationController.removeListener(_activeTickListener!);
          _activeTickListener = null;
        }
        if (_activeStatusListener != null) {
          _mapAnimationController.removeStatusListener(_activeStatusListener!);
          _activeStatusListener = null;
        }
        _isAnimatingCamera = false;
      }
    }

    _activeTickListener = tick;
    _activeStatusListener = onStatus;

    _mapAnimationController.addListener(tick);
    _mapAnimationController.addStatusListener(onStatus);
    _mapAnimationController.forward();
  }

  /// Chamado sempre que o usuário toca ou arrasta o mapa manualmente.
  /// A recentralização automática SÓ acontece se o ícone de cursor (CourseUp)
  /// estiver ativo. Se o usuário estiver em free-look, a câmera não volta.
  void _onMapUserInteracted() {
    if (!_isNavigating) return;

    // Cancela qualquer timer de recentralização pendente
    _autoRecenteringTimer?.cancel();
    _autoRecenteringTimer = null;

    // Desativa cursor/follow → o botão de navegação apaga e câmera fica livre
    if (_followGps || _courseUp) {
      setState(() {
        _followGps = false;
        _courseUp = false;
      });
    }
  }

  /// Retoma o enquadramento suave da câmera com foco nas costas do cursor
  void _resumeCameraFollow() {
    _autoRecenteringTimer?.cancel();
    if (_currentLocation == null) return;
    setState(() {
      _followGps = true;
      _courseUp = true;
    });
    final course = _getForwardCourse();
    final targetRotation = (360.0 - course) % 360.0;
    final camCenter = _getNavigationCameraCenter(_currentLocation!, course);
    _animatedMapMove(camCenter, 17.2, destRotation: targetRotation, durationMs: 800);
  }

  /// Garante que a rota seja automaticamente re-otimizada a partir da localização do entregador
  void _checkAndAutoReoptimize(LatLng latLng) {
    if (_didAutoReoptimize) return;
    final manifestState = ref.read(manifestControllerProvider);
    final stops = manifestState.currentVersion?.stops ?? [];
    if (stops.length > 1) {
      _didAutoReoptimize = true;
      ref.read(manifestControllerProvider.notifier).reoptimizeRoute(
        startLat: latLng.latitude,
        startLng: latLng.longitude,
      ).then((_) {
        if (mounted) {
          _didAutoFit = false;
          final fresh = ref.read(manifestControllerProvider);
          _fitRouteBounds(fresh.currentVersion?.stops ?? [], fresh.roadPolyline);
        }
      });
    }
  }

  Future<void> _fetchCurrentLocation() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return;

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return;
      }

      // 1. Obtem a ultima posicao conhecida imediatamente (zero delay).
      final lastPos = await Geolocator.getLastKnownPosition();
      if (lastPos != null && mounted) {
        final lastLatLng = LatLng(lastPos.latitude, lastPos.longitude);
        setState(() {
          _currentLocation = lastLatLng;
        });
        if (_followGps && !_isAnimatingCamera) {
          if (_isNavigating) {
            final course = _getForwardCourse();
            final camCenter = _getNavigationCameraCenter(lastLatLng, course);
            _animatedMapMove(camCenter, 17.2, destRotation: (360.0 - course) % 360.0, durationMs: 400);
          } else {
            _mapController.move(lastLatLng, 15.0);
          }
        }
        _checkAndAutoReoptimize(lastLatLng);
      }

      // 2. Obtem posicao fresca de satelite com alta precisao.
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
          timeLimit: Duration(seconds: 15),
        ),
      );

      if (!mounted) return;
      final latLng = LatLng(pos.latitude, pos.longitude);
      setState(() {
        _currentLocation = latLng;
        if (pos.heading >= 0 && pos.heading <= 360) {
          _heading = pos.heading;
        }
        _speedKmh = pos.speed * 3.6;
      });
      if (_followGps && !_isAnimatingCamera) {
        if (_isNavigating) {
          final course = _getForwardCourse();
          final camCenter = _getNavigationCameraCenter(latLng, course);
          _animatedMapMove(camCenter, 17.2, destRotation: (360.0 - course) % 360.0, durationMs: 400);
        } else {
          if (_courseUp && _heading != null) {
            _mapController.moveAndRotate(latLng, 15.0, (360.0 - _heading!) % 360.0);
          } else {
            _mapController.move(latLng, 15.0);
          }
        }
      }

      // 3. Re-otimiza automaticamente com o GPS atualizado
      _checkAndAutoReoptimize(latLng);

      // Tracking contínuo para uso em veículo — segue o GPS se follow ativo.
      await _positionSub?.cancel();
      _positionSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
          distanceFilter: 4,
        ),
      ).listen((p) {
        if (!mounted) return;
        final next = LatLng(p.latitude, p.longitude);
        setState(() {
          _currentLocation = next;
          _speedKmh = p.speed * 3.6;
          if (p.heading >= 0 && p.heading <= 360) {
            _heading = p.heading;
          }
        });
        if (_followGps) {
          // Não interrompe animações em andamento
          if (_isAnimatingCamera || _mapAnimationController.isAnimating) return;
          if (_isNavigating) {
            final course = _getForwardCourse();
            final camCenter = _getNavigationCameraCenter(next, course);
            final targetRot = _courseUp ? (360.0 - course) % 360.0 : _mapController.camera.rotation;
            _mapController.moveAndRotate(camCenter, 17.2, targetRot);
          } else {
            final targetRot = (_courseUp && _heading != null) ? (360.0 - _heading!) % 360.0 : _mapController.camera.rotation;
            _mapController.moveAndRotate(next, _mapController.camera.zoom, targetRot);
          }
        }

        // Se estiver navegando, atualiza o trajeto até a próxima parada se o veículo se deslocou mais de 35m
        if (_isNavigating) {
          final stops = ref.read(manifestControllerProvider).currentVersion?.stops ?? [];
          if (stops.isNotEmpty) {
            final target = stops[_selectedStopIndex.clamp(0, stops.length - 1)];
            if (_lastLegFrom != null &&
                LifoCalculator.calculateDistanceMeters(
                  next.latitude,
                  next.longitude,
                  _lastLegFrom!.latitude,
                  _lastLegFrom!.longitude,
                ) > 35) {
              _fetchRouteToTargetStop(target);
            }
            // Atualiza o HUD caso esteja aproximando da parada alvo
            _updateManeuverHud(next, target);
          }
        }
      });

    } catch (_) {
      // GPS indisponivel momentaneamente
    }
  }

  @override
  void dispose() {
    if (_activeTickListener != null) {
      _mapAnimationController.removeListener(_activeTickListener!);
      _activeTickListener = null;
    }
    if (_activeStatusListener != null) {
      _mapAnimationController.removeStatusListener(_activeStatusListener!);
      _activeStatusListener = null;
    }
    _autoRecenteringTimer?.cancel();
    _hudHideTimer?.cancel();
    _mapAnimationController.dispose();
    _positionSub?.cancel();
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    _mapController.dispose();
    _cardDragAnimController.dispose();
    _sheetAnimationController.dispose();
    _sheetExtentNotifier.dispose();
    _routesScrollController.dispose();
    super.dispose();
  }

  void _onInlineSearch(String text) {
    _searchDebounce?.cancel();
    final trimmed = text.trim();
    if (trimmed.length < 3) {
      setState(() {
        _searchResults = [];
        _packageSearchHit = null;
        _packageSearchHitPkg = null;
        _isSearching = false;
      });
      return;
    }

    // Detecta se parece código de barras: sem espaços, puramente alfanumérico
    final isBarcodeQuery = !trimmed.contains(' ') &&
        RegExp(r'^[A-Za-z0-9\-]+$').hasMatch(trimmed);

    if (isBarcodeQuery) {
      // Busca o pacote no manifesto atual
      final stops =
          ref.read(manifestControllerProvider).currentVersion?.stops ?? [];
      DeliveryStop? foundStop;
      PackageItem? foundPkg;
      final query = trimmed.toUpperCase();
      outer:
      for (final stop in stops) {
        for (final pkg in stop.packages) {
          if (pkg.barcode.toUpperCase().contains(query)) {
            foundStop = stop;
            foundPkg = pkg;
            break outer;
          }
        }
      }
      setState(() {
        _packageSearchHit = foundStop;
        _packageSearchHitPkg = foundPkg;
        _searchResults = [];
        _isSearching = false;
      });
      return;
    }

    // Busca por endereço (geocodificação)
    setState(() {
      _packageSearchHit = null;
      _packageSearchHitPkg = null;
      _isSearching = true;
    });
    _searchDebounce = Timer(const Duration(milliseconds: 500), () async {
      final results = await _geocoding.searchAddress(trimmed);
      if (!mounted) return;
      setState(() {
        _searchResults = results;
        _isSearching = false;
      });
    });
  }

  void _collapseSearch() {
    _searchCtrl.clear();
    _searchFocus.unfocus();
    setState(() {
      _searchResults = [];
      _packageSearchHit = null;
      _packageSearchHitPkg = null;
      _isSearching = false;
    });
  }

  Future<void> _addFromSearchResult(GeocodingResult place) async {
    _collapseSearch();
    // Pega GPS fresco para otimizar a ordem a partir da posição real.
    final start = await _ensureRouteStart();
    if (!mounted) return;
    final ok = await ref.read(manifestControllerProvider.notifier).addQuickStop(
      displayName: _extractShortName(place.displayName),
      address: place.displayName,
      latitude: place.latitude,
      longitude: place.longitude,
      startLat: start?.latitude,
      startLng: start?.longitude,
    );
    if (ok && mounted) {
      _fitToCurrentManifest();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Parada adicionada: ${_extractShortName(place.displayName)}'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  /// Extrai nome curto: pega a primeira parte antes da vírgula do display_name.
  String _extractShortName(String displayName) {
    final parts = displayName.split(',');
    if (parts.length >= 2) return '${parts[0].trim()}, ${parts[1].trim()}';
    return parts.first.trim();
  }

  Future<bool> _confirmRemoveDismiss(DeliveryStop stop) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remover parada'),
        content: Text('Remover "${stop.recipientName}" da rota? A rota sera re-otimizada.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remover', style: TextStyle(color: AppColors.circuitRed)),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      final start = await _ensureRouteStart();
      if (!mounted) return false;
      await ref.read(manifestControllerProvider.notifier).removeStop(
        stop.id,
        startLat: start?.latitude,
        startLng: start?.longitude,
      );
      if (mounted) _fitToCurrentManifest();
      return true;
    }
    return false;
  }

  Future<void> _confirmRemoveStop(DeliveryStop stop) async {
    await _confirmRemoveDismiss(stop);
  }

  void _fitPoints(List<LatLng?> points) {
    final clean = [for (final p in points) ?p];
    if (clean.isEmpty) return;
    // Área visível: tela cheia menos a sheet (~45%) e os controles do topo.
    final size = MediaQuery.of(context).size;
    final frame = LogisticsMapCanvas.frameForPoints(
      points: clean,
      viewportWidth: size.width,
      viewportHeight: size.height * 0.55,
    );
    debugPrint(
      'LIFO frame: ${clean.length} pts -> '
      '${frame.center.latitude.toStringAsFixed(4)},'
      '${frame.center.longitude.toStringAsFixed(4)} '
      'z${frame.zoom.toStringAsFixed(1)}',
    );
    try {
      _mapController.move(frame.center, frame.zoom);
    } catch (e) {
      debugPrint('LIFO frame falhou: $e');
    }
  }

  void _fitRouteBounds(List<DeliveryStop> stops, List<LatLng> polyline) {
    final pending = stops.where(
      (s) => s.status == StopStatus.pending || s.status == StopStatus.inTransit,
    ).toList();
    final targetStops = pending.isNotEmpty ? pending : stops;
    final List<LatLng> pointsToFit = [
      ...polyline,
      for (final s in targetStops) LatLng(s.latitude, s.longitude),
    ];
    // Só inclui _currentLocation se estiver razoavelmente próximo às paradas (< 25km),
    // evitando esticar a câmera pelo mapa se o GPS estiver em outra cidade/estado.
    if (_currentLocation != null && targetStops.isNotEmpty) {
      final firstTarget = targetStops.first;
      final distKm = LifoCalculator.calculateDistanceMeters(
        _currentLocation!.latitude,
        _currentLocation!.longitude,
        firstTarget.latitude,
        firstTarget.longitude,
      ) / 1000.0;
      if (distKm <= 25.0) {
        pointsToFit.add(_currentLocation!);
      }
    }
    _fitPoints(pointsToFit);
  }




  void _recenterMap(List<DeliveryStop> stops) {
    // Modo visão geral: norte pra cima + enquadra rota + GPS.
    setState(() {
      _followGps = true;
      _courseUp = false;
    });
    try {
      _mapController.rotate(0);
    } catch (_) {}
    if (_currentLocation != null && stops.isEmpty) {
      _mapController.move(_currentLocation!, 15.0);
      return;
    }
    // Enquadra rota real + GPS em vez de só pular para um ponto.
    final polyline = ref.read(manifestControllerProvider).roadPolyline;
    if (stops.isNotEmpty) {
      _fitRouteBounds(stops, polyline);
    } else if (_currentLocation != null) {
      _mapController.move(_currentLocation!, 15.0);
    }
  }

  void _toggleCourseUp() {
    // Modo navegação Course-Up estilo Circuit: câmera gira com a direção do veículo.
    setState(() {
      _courseUp = !_courseUp;
      _followGps = true;
    });
    if (_courseUp) {
      final course = _getForwardCourse();
      final targetRotation = (360.0 - course) % 360.0;
      if (_currentLocation != null) {
        final camCenter = _isNavigating
            ? _getNavigationCameraCenter(_currentLocation!, course)
            : _currentLocation!;
        _animatedMapMove(camCenter, _isNavigating ? 17.0 : 16.5, destRotation: targetRotation, durationMs: 650);
      } else {
        try {
          _mapController.rotate(targetRotation);
        } catch (_) {}
      }
    } else {
      _animatedMapMove(_mapController.camera.center, _mapController.camera.zoom, destRotation: 0, durationMs: 500);
    }
  }

  void _openScanner() async {
    final result = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder: (_) => const CargoScannerScreen(),
      ),
    );
    // Se o scanner sinalizou para navegar até uma parada específica
    if (result != null && result['navigateTo'] is String && mounted) {
      final stopId = result['navigateTo'] as String;
      final stops = ref.read(manifestControllerProvider).currentVersion?.stops ?? [];
      final listIdx = stops.indexWhere((s) => s.id == stopId);
      if (listIdx != -1) {
        setState(() => _selectedStopIndex = listIdx);
        _startInAppNavigation(stops[listIdx], forceFollow: true);
      }
    }
  }

  void _openVehicleBayModal() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const VehicleBayScreen(),
      ),
    );
  }

  void _openAuditModal() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const ManifestVersionsScreen(),
      ),
    );
  }

  void _openOptionsMenu(BuildContext ctx, bool isDark, List<DeliveryStop> stops) {
    final bg = isDark ? const Color(0xFF0F172A) : Colors.white;
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
    final divColor = isDark ? const Color(0xFF1E293B) : const Color(0xFFE2E8F0);

    showModalBottomSheet(
      context: ctx,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) {
        return Container(
          decoration: BoxDecoration(
            color: bg,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).padding.bottom + 8,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Handle
                Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    color: divColor,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                _optionTile(
                  icon: Icons.alt_route,
                  label: 'Otimizar Rota',
                  subtitle: 'Recalcula a ordem ideal das paradas',
                  textColor: textColor,
                  subColor: subColor,
                  onTap: () { Navigator.pop(ctx); _reoptimizeWithGps(); },
                ),
                Divider(height: 1, color: divColor),
                _optionTile(
                  icon: Icons.add_location_alt_outlined,
                  label: 'Nova Parada',
                  subtitle: 'Adiciona uma entrega manualmente',
                  textColor: textColor,
                  subColor: subColor,
                  onTap: () { Navigator.pop(ctx); _openAddStop(); },
                ),
                Divider(height: 1, color: divColor),
                _optionTile(
                  icon: Icons.upload_file_outlined,
                  label: 'Importar Manifesto',
                  subtitle: 'Carrega um arquivo de entregas',
                  textColor: textColor,
                  subColor: subColor,
                  onTap: () { Navigator.pop(ctx); _openImport(); },
                ),
                Divider(height: 1, color: divColor),
                _optionTile(
                  icon: Icons.local_shipping_outlined,
                  label: 'Carregar Veículo (LIFO)',
                  subtitle: 'Organiza a carga no baú',
                  textColor: textColor,
                  subColor: subColor,
                  onTap: () { Navigator.pop(ctx); _openVehicleBayModal(); },
                ),
                Divider(height: 1, color: divColor),
                _optionTile(
                  icon: Icons.qr_code_scanner,
                  label: 'Bipar Carga',
                  subtitle: 'Conferência de volumes por código',
                  textColor: textColor,
                  subColor: subColor,
                  onTap: () { Navigator.pop(ctx); _openScanner(); },
                ),
                Divider(height: 1, color: divColor),
                _optionTile(
                  icon: Icons.history,
                  label: 'Versões da Rota',
                  subtitle: 'Histórico e snapshots do manifesto',
                  textColor: textColor,
                  subColor: subColor,
                  onTap: () { Navigator.pop(ctx); _openAuditModal(); },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _optionTile({
    required IconData icon,
    required String label,
    required String subtitle,
    required Color textColor,
    required Color subColor,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: const Color(0xFF2563EB).withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, size: 20, color: const Color(0xFF2563EB)),
      ),
      title: Text(
        label,
        style: TextStyle(
          color: textColor,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(color: subColor, fontSize: 12),
      ),
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
    );
  }

  Future<void> _openAddStop() async {
    final saved = await AddStopSheet.show(
      context,
      startLat: _currentLocation?.latitude,
      startLng: _currentLocation?.longitude,
    );
    if (saved == true && mounted) {
      _fitToCurrentManifest();
    }
  }

  Future<void> _openImport() async {
    final imported = await ImportManifestSheet.show(
      context,
      startLat: _currentLocation?.latitude,
      startLng: _currentLocation?.longitude,
    );
    if (imported == true && mounted) {
      _fitToCurrentManifest();

      // ── Pede o nome da rota ─────────────────────────────────────────────
      final isDark = Theme.of(context).brightness == Brightness.dark;
      final nameCtrl = TextEditingController();
      final routeName = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(
            'Dar nome à rota',
            style: TextStyle(
              color: isDark ? Colors.white : const Color(0xFF0F172A),
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Como você quer chamar esta rota?',
                style: TextStyle(
                  color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: nameCtrl,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                style: TextStyle(
                  color: isDark ? Colors.white : const Color(0xFF0F172A),
                  fontSize: 15,
                ),
                decoration: InputDecoration(
                  hintText: 'Ex: Rota Centro — Manhã',
                  hintStyle: TextStyle(
                    color: isDark ? const Color(0xFF475569) : const Color(0xFF94A3B8),
                    fontSize: 14,
                  ),
                  filled: true,
                  fillColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(
                      color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(
                      color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: Color(0xFF2563EB), width: 1.5),
                  ),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: Text(
                'Pular',
                style: TextStyle(
                  color: isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            ElevatedButton(
              onPressed: () {
                final name = nameCtrl.text.trim();
                Navigator.pop(ctx, name.isNotEmpty ? name : null);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2563EB),
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              child: const Text('Confirmar', style: TextStyle(fontWeight: FontWeight.w600)),
            ),
          ],
        ),
      );

      if (routeName != null && mounted) {
        await ref.read(manifestControllerProvider.notifier).renameCurrentManifest(routeName);
      }

      // ── Sucesso ─────────────────────────────────────────────────────────
      if (!mounted) return;
      final s = ref.read(manifestControllerProvider);
      final v = s.currentVersion;
      if (v != null && mounted) {
        await ImportSuccessDialog.show(
          context,
          version: v,
          totalDurationSeconds: s.totalDurationSeconds,
          routeComputedAt: s.routeComputedAt,
          totalDistanceMeters: s.totalDistanceMeters,
        );
      }
    }
  }


  void _fitToCurrentManifest() {
    // Pós-frame: garante viewport com tamanho válido antes do fit.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final s = ref.read(manifestControllerProvider);
      final freshStops = s.currentVersion?.stops ?? [];
      if (freshStops.isNotEmpty) {
        debugPrint(
          'LIFO import: ${freshStops.length} paradas, '
          '${s.roadPolyline.length} pts polyline, '
          'online=${s.isOnlineRouting}',
        );
        setState(() {
          _selectedStopIndex = _nextPendingIndex(freshStops);
        });
        _fitRouteBounds(freshStops, s.roadPolyline);
      }
    });
  }

  Future<void> _onGpsButtonPressed(List<DeliveryStop> stops) async {
    setState(() {
      _followGps = true;
      _courseUp = false;
    });
    try {
      _mapController.rotate(0);
    } catch (_) {}

    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
          timeLimit: Duration(seconds: 8),
        ),
      );
      if (!mounted) return;
      final latLng = LatLng(pos.latitude, pos.longitude);
      setState(() {
        _currentLocation = latLng;
        _speedKmh = pos.speed * 3.6;
      });
      _mapController.move(latLng, 16.0);
    } catch (_) {
      if (_currentLocation != null) {
        _mapController.move(_currentLocation!, 16.0);
      } else {
        _recenterMap(stops);
      }
    }
  }

  /// Posição de partida da rota: busca fix fresco de satelite do GPS
  /// para que a parada 1 seja de fato a mais perto de onde você está.
  Future<LatLng?> _ensureRouteStart() async {
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
          timeLimit: Duration(seconds: 8),
        ),
      );
      final fix = LatLng(pos.latitude, pos.longitude);
      if (mounted) setState(() => _currentLocation = fix);
      return fix;
    } catch (_) {
      if (_currentLocation != null) return _currentLocation;
      try {
        final last = await Geolocator.getLastKnownPosition();
        if (last != null) {
          final fix = LatLng(last.latitude, last.longitude);
          if (mounted) setState(() => _currentLocation = fix);
          return fix;
        }
      } catch (_) {}
      return null;
    }
  }

  Future<void> _reoptimizeWithGps() async {
    final start = await _ensureRouteStart();
    if (!mounted) return;
    if (start == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Sem sinal de GPS: ordem calculada sem ponto de partida.'),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Otimizando rota a partir da sua localização atual...'),
          duration: Duration(seconds: 2),
        ),
      );
    }
    await ref.read(manifestControllerProvider.notifier).reoptimizeRoute(
          startLat: start?.latitude,
          startLng: start?.longitude,
        );
    if (mounted) {
      _fitToCurrentManifest();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Rota otimizada com sucesso a partir da sua localização!'),
          backgroundColor: Color(0xFF16A34A),
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  /// Calcula o azimute (bearing) geográfico inicial entre dois pontos em graus (0 = Norte, 90 = Leste).
  double _calculateBearing(LatLng from, LatLng to) {
    final lat1 = from.latitude * pi / 180.0;
    final lon1 = from.longitude * pi / 180.0;
    final lat2 = to.latitude * pi / 180.0;
    final lon2 = to.longitude * pi / 180.0;
    final dLon = lon2 - lon1;

    final y = sin(dLon) * cos(lat2);
    final x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon);
    final radians = atan2(y, x);
    return (radians * 180.0 / pi + 360.0) % 360.0;
  }

  /// Obtém o azimute geográfico (0-360°) para onde a frente do veículo / rua à frente está apontando.
  double _getForwardCourse() {
    // 1. Se em movimento (velocidade > 1.2 km/h) ou com heading de bússola válido
    if (_heading != null && _heading! >= 0 && _heading! <= 360) {
      if (_speedKmh > 1.2) {
        return _heading!;
      }
    }

    if (_currentLocation != null) {
      final manifestState = ref.read(manifestControllerProvider);
      final stops = manifestState.currentVersion?.stops ?? [];
      final polyline = (_isNavigating && _legPolyline.length > 1)
          ? _legPolyline
          : (manifestState.roadPolyline.isNotEmpty
              ? manifestState.roadPolyline
              : stops.map((s) => LatLng(s.latitude, s.longitude)).toList());

      // 2. Se temos polilinha viária e o veículo está na rota (< 250m)
      if (polyline.length > 1) {
        int closestIdx = 0;
        double minD = double.infinity;
        for (int i = 0; i < polyline.length; i++) {
          final d = LifoCalculator.calculateDistanceMeters(
            _currentLocation!.latitude,
            _currentLocation!.longitude,
            polyline[i].latitude,
            polyline[i].longitude,
          );
          if (d < minD) {
            minD = d;
            closestIdx = i;
          }
        }

        // Se está na rota, calcula a direção viária real da rua à frente
        if (minD < 250.0) {
          for (int j = closestIdx + 1; j < polyline.length; j++) {
            final distAhead = LifoCalculator.calculateDistanceMeters(
              polyline[closestIdx].latitude,
              polyline[closestIdx].longitude,
              polyline[j].latitude,
              polyline[j].longitude,
            );
            if (distAhead >= 15.0) {
              return _calculateBearing(polyline[closestIdx], polyline[j]);
            }
          }
          if (closestIdx + 1 < polyline.length) {
            return _calculateBearing(polyline[closestIdx], polyline[closestIdx + 1]);
          }
        }
      }

      // 3. Se temos bússola do celular válida parada, usa ela com prioridade antes da linha reta
      if (_heading != null && _heading! > 0) {
        return _heading!;
      }

      // 4. Fallback: azimute direto até a parada selecionada
      final idx = _selectedStopIndex.clamp(0, stops.length - 1);
      if (stops.isNotEmpty) {
        final target = LatLng(stops[idx].latitude, stops[idx].longitude);
        final distToTarget = LifoCalculator.calculateDistanceMeters(
          _currentLocation!.latitude,
          _currentLocation!.longitude,
          target.latitude,
          target.longitude,
        );
        if (distToTarget > 10.0) {
          return _calculateBearing(_currentLocation!, target);
        }
      }
    }

    return _heading ?? 0.0;
  }

  /// Projeta o centro da câmera ~70 metros à frente do veículo na direção da rua.
  /// Isso coloca a câmera diretamente "nas costas do cursor", trazendo o veículo
  /// para o terço inferior da tela (logo acima do card de navegação) com ampla visão da rua adiante.
  LatLng _getNavigationCameraCenter(LatLng vehicleLoc, double courseDeg) {
    const double forwardOffsetMeters = 70.0;
    final rad = courseDeg * pi / 180.0;
    final dLat = (forwardOffsetMeters / 111195.0) * cos(rad);
    final dLng = (forwardOffsetMeters / (111195.0 * cos(vehicleLoc.latitude * pi / 180.0))) * sin(rad);
    return LatLng(vehicleLoc.latitude + dLat, vehicleLoc.longitude + dLng);
  }

  /// Retorna o índice da primeira parada pendente/em-trânsito da lista.
  /// Se todas estiverem concluídas/falhadas retorna o índice atual (ou 0).
  int _nextPendingIndex(List<DeliveryStop> stops) {
    final pendingIdx = stops.indexWhere(
      (s) => s.status == StopStatus.pending || s.status == StopStatus.inTransit,
    );
    if (pendingIdx != -1) return pendingIdx;
    return _selectedStopIndex.clamp(0, stops.length - 1);
  }

  /// Busca o traçado viário exclusivamente da localização atual até a próxima parada
  Future<void> _fetchRouteToTargetStop(DeliveryStop targetStop) async {
    final from = _currentLocation;
    if (from == null) return;

    if (_lastLegTargetStopId == targetStop.id &&
        _lastLegFrom != null &&
        LifoCalculator.calculateDistanceMeters(
          from.latitude,
          from.longitude,
          _lastLegFrom!.latitude,
          _lastLegFrom!.longitude,
        ) < 25) {
      return;
    }

    _lastLegTargetStopId = targetStop.id;
    _lastLegFrom = from;

    final targetPoint = LatLng(targetStop.latitude, targetStop.longitude);

    try {
      final leg = await _routingService.fetchLegRoute(
        from: from,
        to: targetPoint,
      );

      if (!mounted) return;

      if (leg != null && leg.points.isNotEmpty) {
        setState(() {
          _legPolyline = leg.points;
          _lastHudDist = -1;
        });
        _showManeuverHud();
      } else {
        setState(() {
          _legPolyline = [from, targetPoint];
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _legPolyline = [from, targetPoint];
        });
      }
    }
  }

  /// Exibe o HUD de manobra por alguns segundos (auto-oculta como Waze)
  void _showManeuverHud({bool resetTimer = true}) {
    if (!mounted) return;
    setState(() => _hudVisible = true);
    if (resetTimer) {
      _hudHideTimer?.cancel();
      _hudHideTimer = Timer(const Duration(seconds: 6), () {
        if (mounted) setState(() => _hudVisible = false);
      });
    }
  }

  /// Atualiza o HUD durante a navegação conforme aproximação real da parada
  void _updateManeuverHud(LatLng pos, DeliveryStop targetStop) {
    if (!_isNavigating) return;
    final dist = LifoCalculator.calculateDistanceMeters(
      pos.latitude,
      pos.longitude,
      targetStop.latitude,
      targetStop.longitude,
    );
    // Auto-exibe o HUD quando o motorista estiver a menos de 250 metros da parada alvo
    if (dist < 250 && (_lastHudDist - dist).abs() > 40) {
      _lastHudDist = dist;
      _showManeuverHud();
    }
  }


  void _startInAppNavigation(DeliveryStop stop, {bool forceFollow = false}) {
    _fetchRouteToTargetStop(stop);
    _showManeuverHud();

    final alreadyNavigating = _isNavigating;

    setState(() {
      _isNavigating = true;
      // forceFollow = true: botão Navegar pressionado explicitamente → sempre
      //   reativa cursor e follow, independente do estado anterior.
      // forceFollow = false: mudança de parada via swipe → só ativa na primeira
      //   vez que a navegação começa; se o usuário estava em free-look, mantém.
      if (forceFollow || !alreadyNavigating) {
        _courseUp = true;
        _followGps = true;
      }
    });

    // Move a câmera se cursor estiver ativo (pode ter sido reativado acima)
    if (_courseUp && _followGps) {
      final course = _getForwardCourse();
      final targetRotation = (360.0 - course) % 360.0;
      if (_currentLocation != null) {
        final camCenter = _getNavigationCameraCenter(_currentLocation!, course);
        _animatedMapMove(
          camCenter,
          17.2,
          destRotation: targetRotation,
          durationMs: 800,
        );
      } else {
        final targetStop = LatLng(stop.latitude, stop.longitude);
        _animatedMapMove(targetStop, 16.5, durationMs: 800);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        final user = ref.read(authControllerProvider).user;
        NotificationService.instance.checkExpiryAndNotify(context, user);
      }
    });

    ref.listen<ManifestState>(manifestControllerProvider, (prev, next) {
      if (!_didAutoReoptimize &&
          _currentLocation != null &&
          (next.currentVersion?.stops.length ?? 0) > 1 &&
          !next.hasGpsStart) {
        _checkAndAutoReoptimize(_currentLocation!);
      }
    });

    final manifestState = ref.watch(manifestControllerProvider);
    final currentVersion = manifestState.currentVersion;
    final stops = currentVersion?.stops ?? [];

    final LatLng defaultCenter = stops.isNotEmpty
        ? LatLng(stops.first.latitude, stops.first.longitude)
        : (_currentLocation ?? const LatLng(-14.2350, -51.9253));

    final curIdx = _selectedStopIndex.clamp(0, stops.isNotEmpty ? stops.length - 1 : 0);
    final targetStop = stops.isNotEmpty ? stops[curIdx] : null;

    // Se estiver navegando e mudou a parada alvo, busca traçado até ela
    if (_isNavigating && targetStop != null && _currentLocation != null && _lastLegTargetStopId != targetStop.id) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _fetchRouteToTargetStop(targetStop);
      });
    }

    // Quando navegando: desenha EXCLUSIVAMENTE o caminho até a próxima parada!
    final List<LatLng> fallbackRoutePoints = stops.map((s) => LatLng(s.latitude, s.longitude)).toList();
    final List<LatLng> effectivePolyline;
    if (_isNavigating && targetStop != null && _currentLocation != null) {
      if (_legPolyline.isNotEmpty && _lastLegTargetStopId == targetStop.id) {
        effectivePolyline = _legPolyline;
      } else {
        effectivePolyline = [_currentLocation!, LatLng(targetStop.latitude, targetStop.longitude)];
      }
    } else {
      effectivePolyline = manifestState.roadPolyline.isNotEmpty
          ? manifestState.roadPolyline
          : fallbackRoutePoints;
    }

    final mapMarkers = stops.asMap().entries.map((entry) {
      final index = entry.key;
      final stop = entry.value;
      return MapCanvasMarker(
        sequenceIndex: stop.sequenceIndex,
        position: LatLng(stop.latitude, stop.longitude),
        isSelected: index == _selectedStopIndex,
        isCompleted: stop.status == StopStatus.completed,
        isFailed: stop.status == StopStatus.failed,
        slotColor: stop.spatialSlot.visualColor,
      );
    }).toList();

    final bool isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      drawer: _buildCircuitDrawer(context, ref, currentVersion),
      body: SizedBox.expand(
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 1. ISOLATED LOGISTICS MAP CANVAS (Ocupa SEMPRE 100% da tela)
            Positioned.fill(
              child: RepaintBoundary(
                child: LogisticsMapCanvas(
                  mapController: _mapController,
                  initialCenter: stops.isNotEmpty ? defaultCenter : (_currentLocation ?? defaultCenter),
                  initialZoom: (stops.isNotEmpty || _currentLocation != null) ? 13.5 : 4.0,
                  markers: mapMarkers,
                  routePolyline: effectivePolyline,
                  isSatellite: _isSatelliteLayer,
                  isDark: isDark,
                  currentLocationPin: _currentLocation,
                  headingDegrees: _heading,
                  isNavigating: _isNavigating,
                  onUserInteraction: _onMapUserInteracted,
                  onMapReady: () {
                    if (!_didAutoFit && stops.isNotEmpty) {
                      _didAutoFit = true;
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) _fitRouteBounds(stops, effectivePolyline);
                      });
                    }
                  },
                  onMarkerTap: (sequenceIndex) {
                    final idx = stops.indexWhere((s) => s.sequenceIndex == sequenceIndex);
                    if (idx != -1) {
                      setState(() {
                        _selectedStopIndex = idx;
                        _isNavigating = true;
                        _followGps = false;
                      });
                      _animatedMapMove(
                        LatLng(stops[idx].latitude, stops[idx].longitude),
                        16.0,
                        durationMs: 650,
                      );
                    }
                  },
                ),
              ),
            ),

            // 2. TOP FLOATING CONTROLS (Ancorados no topo com Positioned)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildFloatingCircleButton(
                        context: context,
                        icon: Icons.menu,
                        onTap: () => _scaffoldKey.currentState?.openDrawer(),
                      ),

                      if (_isNavigating && targetStop != null)
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: IgnorePointer(
                              ignoring: !_hudVisible,
                              child: AnimatedOpacity(
                                opacity: _hudVisible ? 1.0 : 0.0,
                                duration: const Duration(milliseconds: 350),
                                curve: Curves.easeInOut,
                                child: GestureDetector(
                                  onTap: () {
                                    HapticFeedback.lightImpact();
                                    _showManeuverHud();
                                    _animatedMapMove(
                                      LatLng(targetStop.latitude, targetStop.longitude),
                                      16.5,
                                      durationMs: 600,
                                    );
                                  },
                                  child: _buildManeuverHud(targetStop: targetStop),
                                ),
                              ),
                            ),
                          ),
                        )
                      else
                        const Spacer(),

                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_isNavigating && !_followGps) ...[
                            _buildFloatingCircleButton(
                              context: context,
                              icon: Icons.gps_fixed,
                              tooltip: 'Recentralizar no veículo',
                              isActive: true,
                              onTap: _resumeCameraFollow,
                            ),
                            const SizedBox(height: 10),
                          ],
                          _buildFloatingCircleButton(
                            context: context,
                            icon: Icons.alt_route,
                            tooltip: 'Re-otimizar Rota LIFO',
                            onTap: _reoptimizeWithGps,
                          ),
                          const SizedBox(height: 10),
                          _buildFloatingCircleButton(
                            context: context,
                            icon: _isSatelliteLayer ? Icons.map : Icons.layers_outlined,
                            tooltip: 'Alternar Camada',
                            onTap: () {
                              setState(() {
                                _isSatelliteLayer = !_isSatelliteLayer;
                              });
                            },
                          ),
                          const SizedBox(height: 10),
                          _buildFloatingCircleButton(
                            context: context,
                            icon: Icons.my_location,
                            tooltip: 'Minha Localização GPS',
                            onTap: () => _onGpsButtonPressed(stops),
                          ),
                          const SizedBox(height: 10),
                          _buildFloatingCircleButton(
                            context: context,
                            icon: Icons.navigation,
                            tooltip: 'Modo Course-Up (rua apontando para cima)',
                            isActive: _courseUp,
                            onTap: _toggleCourseUp,
                          ),
                          if (_currentLocation != null) ...[
                            const SizedBox(height: 10),
                            _buildSpeedPill(context),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // 3. NAVEGAÇÃO ATIVA: Card fixo com animação de deslize lateral e feedback sonoro/tátil
            if (_isNavigating && stops.isNotEmpty)
              Positioned(
                left: 14,
                right: 14,
                bottom: 12 + MediaQuery.of(context).padding.bottom,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragStart: (_) {
                    _cardDragAnimController.stop();
                  },
                  onHorizontalDragUpdate: (details) {
                    setState(() {
                      _cardDragDx += details.delta.dx;
                    });
                  },
                  onHorizontalDragEnd: (details) {
                    final velocity = details.primaryVelocity ?? 0;
                    if (_cardDragDx < -45 || velocity < -180) {
                      _advanceToNextStop(stops);
                    } else if (_cardDragDx > 45 || velocity > 180) {
                      _goToPreviousStop(stops);
                    } else {
                      _animateCardDragTo(0.0, duration: const Duration(milliseconds: 200), curve: Curves.easeOutCubic);
                    }
                  },
                  child: Transform.translate(
                    offset: Offset(_cardDragDx, 0),
                    child: Transform.rotate(
                      angle: (_cardDragDx / 3200).clamp(-0.05, 0.05),
                      child: _buildActiveNavigationCard(
                        isDark: isDark,
                        stop: stops[_selectedStopIndex.clamp(0, stops.length - 1)],
                        currentIndex: _selectedStopIndex.clamp(0, stops.length - 1),
                        totalStops: stops.length,
                        timeLabel: _stopTimeLabel(
                          index: _selectedStopIndex.clamp(0, stops.length - 1),
                          stop: stops[_selectedStopIndex.clamp(0, stops.length - 1)],
                          arrivalOffsets: manifestState.arrivalOffsets,
                          routeComputedAt: manifestState.routeComputedAt,
                          isOnlineRouting: manifestState.isOnlineRouting,
                        ),
                        onNavigate: () {
                          final curIdx = _selectedStopIndex.clamp(0, stops.length - 1);
                          final curStop = stops[curIdx];
                          if (curStop.status == StopStatus.completed ||
                              curStop.status == StopStatus.failed) {
                            final nextIdx = _nextPendingIndex(stops);
                            if (nextIdx > curIdx) {
                              _advanceToNextStop(stops);
                            } else if (nextIdx < curIdx) {
                              _goToPreviousStop(stops);
                            } else {
                              // Botão Navegar → sempre forçar câmera nas costas do cursor
                              _startInAppNavigation(stops[nextIdx], forceFollow: true);
                            }
                          } else {
                            // Botão Navegar → sempre forçar câmera nas costas do cursor
                            _startInAppNavigation(curStop, forceFollow: true);
                          }
                        },
                        onNext: () => _advanceToNextStop(stops),
                        onPrevious: () => _goToPreviousStop(stops),
                        onMarkFailed: () {
                          final curIdx = _selectedStopIndex.clamp(0, stops.length - 1);
                          final isCurrentlyFailed = stops[curIdx].status == StopStatus.failed;
                          final newStatus = isCurrentlyFailed ? StopStatus.pending : StopStatus.failed;
                          ref.read(manifestControllerProvider.notifier).updateStopStatus(
                            stops[curIdx].id,
                            newStatus,
                          );
                          if (!isCurrentlyFailed) {
                            _advanceToNextStop(stops);
                          }
                        },
                        onMarkCompleted: () {
                          final curIdx = _selectedStopIndex.clamp(0, stops.length - 1);
                          final isCurrentlyCompleted = stops[curIdx].status == StopStatus.completed;
                          final newStatus = isCurrentlyCompleted ? StopStatus.pending : StopStatus.completed;
                          ref.read(manifestControllerProvider.notifier).updateStopStatus(
                            stops[curIdx].id,
                            newStatus,
                          );
                          if (!isCurrentlyCompleted) {
                            final allDone = stops.every((s) => s.id == stops[curIdx].id || s.status == StopStatus.completed);
                            if (allDone) {
                              setState(() {
                                _isNavigating = false;
                                _courseUp = false;
                                _cardDragDx = 0.0;
                              });
                              _animatedMapMove(_mapController.camera.center, _mapController.camera.zoom, destRotation: 0, durationMs: 400);
                            } else {
                              _advanceToNextStop(stops);
                            }
                            ScaffoldMessenger.of(context).hideCurrentSnackBar();
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(allDone
                                    ? 'TODAS AS PARADAS ENTREGUES!'
                                    : 'Parada #${stops[curIdx].sequenceIndex} ENTREGUE! Avançando para a próxima...'),
                                duration: const Duration(seconds: 2),
                                backgroundColor: const Color(0xFF16A34A),
                              ),
                            );
                          }
                        },
                        onUndo: () {
                          final curIdx = _selectedStopIndex.clamp(0, stops.length - 1);
                          final curStop = stops[curIdx];
                          ref.read(manifestControllerProvider.notifier).updateStopStatus(
                            curStop.id,
                            StopStatus.pending,
                          );
                          HapticFeedback.mediumImpact();
                          SystemSound.play(SystemSoundType.click);
                          setState(() {});
                          ScaffoldMessenger.of(context).hideCurrentSnackBar();
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Parada #${curStop.sequenceIndex} desfeita! Status retornado para pendente.'),
                              duration: const Duration(seconds: 2),
                              backgroundColor: const Color(0xFF2563EB),
                            ),
                          );
                        },
                        onClose: () {
                          setState(() {
                            _isNavigating = false;
                            _courseUp = false;
                            _cardDragDx = 0.0;
                            _lastAutoScrolledIndex = null;
                          });
                          _animatedMapMove(_mapController.camera.center, _mapController.camera.zoom, destRotation: 0, durationMs: 400);
                        },
                      ),
                    ),
                  ),
                ),
              )
            else
              // 3. MODO VISÃO GERAL: Bottom sheet interativo com altura controlável e lista independente
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: ValueListenableBuilder<double>(
                  valueListenable: _sheetExtentNotifier,
                  builder: (context, extent, child) {
                    return SizedBox(
                      height: MediaQuery.of(context).size.height * extent,
                      child: child,
                    );
                  },
                  child: RepaintBoundary(
                    child: _buildCircuitBottomSheet(
                      context: context,
                      currentVersion: currentVersion,
                      stops: stops,
                      isOnlineRouting: manifestState.isOnlineRouting,
                      totalDurationSeconds: manifestState.totalDurationSeconds,
                      arrivalOffsets: manifestState.arrivalOffsets,
                      routeComputedAt: manifestState.routeComputedAt,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildFloatingCircleButton({
    required BuildContext context,
    required IconData icon,
    required VoidCallback onTap,
    String? tooltip,
    bool isActive = false,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isActive
        ? AppColors.circuitBlue
        : (isDark ? AppColors.carbonSurface : AppColors.lightSurface);
    final border = isActive
        ? AppColors.circuitBlueGlow
        : (isDark ? AppColors.carbonBorder : AppColors.lightBorder);
    final iconColor = isActive
        ? Colors.white
        : (isDark ? AppColors.textWhite : AppColors.lightTextPrimary);
    return Tooltip(
      message: tooltip ?? '',
      child: Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          color: bg.withValues(alpha: 0.95),
          shape: BoxShape.circle,
          border: Border.all(color: border, width: 1.2),
          boxShadow: [
            BoxShadow(
              color: isActive
                  ? AppColors.circuitBlue.withValues(alpha: 0.5)
                  : Colors.black.withValues(alpha: isDark ? 0.5 : 0.18),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(23),
            onTap: onTap,
            child: Icon(icon, color: iconColor, size: 22),
          ),
        ),
      ),
    );
  }

  Widget _buildSpeedPill(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? AppColors.carbonSurface : AppColors.lightSurface;
    final border = isDark ? AppColors.carbonBorder : AppColors.lightBorder;
    final fg = isDark ? AppColors.textWhite : AppColors.lightTextPrimary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: bg.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: border, width: 1.2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.5 : 0.18),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Text(
        '${_speedKmh.toStringAsFixed(0)} km/h',
        style: TextStyle(
          color: fg,
          fontSize: 12,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  Widget _buildCircuitBottomSheet({
    required BuildContext context,
    required dynamic currentVersion,
    required List<DeliveryStop> stops,
    required bool isOnlineRouting,
    required double totalDurationSeconds,
    required List<double> arrivalOffsets,
    required DateTime? routeComputedAt,
  }) {
    final int totalStops = stops.length;
    final int loadedCount = currentVersion?.loadedPackagesCount ?? 0;
    final int totalCount = currentVersion?.totalPackagesInStops ?? 0;
    final double totalWeight = stops.fold(0.0, (acc, s) => acc + s.packages.fold(0.0, (pAcc, p) => pAcc + p.weightKg));

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final sheetBg = isDark ? AppColors.carbonSurface : AppColors.lightSurface;
    final sheetBorder = isDark ? AppColors.carbonBorder : AppColors.lightBorder;
    final inputBg = isDark ? AppColors.carbonSurfaceInput : AppColors.lightSurfaceInput;
    final inputBorder = isDark ? AppColors.carbonBorderSubtle : AppColors.lightBorderSubtle;
    final titleColor = isDark ? AppColors.textWhite : AppColors.lightTextPrimary;
    final subColor = isDark ? AppColors.textSlate : AppColors.lightTextSecondary;
    final mutedColor = isDark ? AppColors.textMuted : AppColors.lightTextMuted;

    if (currentVersion == null || stops.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          color: sheetBg,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border.all(color: sheetBorder, width: 1.2),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.7 : 0.18),
              blurRadius: 20,
              offset: const Offset(0, -6),
            ),
          ],
        ),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragUpdate: _onSheetDragUpdate,
          onVerticalDragEnd: _onSheetDragEnd,
          child: ListView(
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
            children: [
              Center(
                child: GestureDetector(
                  onTap: _toggleSheetSize,
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 30),
                    color: Colors.transparent,
                    child: Container(
                      width: 38,
                      height: 4.5,
                      decoration: BoxDecoration(
                        color: sheetBorder,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              const Icon(Icons.local_shipping_outlined, size: 48, color: AppColors.circuitBlueGlow),
              const SizedBox(height: 12),
              Text(
                'Nenhum manifesto ativo',
                textAlign: TextAlign.center,
                style: TextStyle(color: titleColor, fontSize: 17, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              Text(
                'Cadastre a primeira parada com endereço real — o app calcula a rota e a posição LIFO de cada volume.',
                textAlign: TextAlign.center,
                style: TextStyle(color: subColor, fontSize: 13),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _openImport,
                icon: const Icon(Icons.upload_file_outlined, size: 18),
                label: const Text('Importar manifesto'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _openAddStop,
                icon: const Icon(Icons.add_location_alt_outlined, size: 18),
                label: const Text('Adicionar parada manual'),
              ),
            ],
          ),
        ),
      );
    }

    final bool hasRealEta =
        isOnlineRouting && totalDurationSeconds > 0 && routeComputedAt != null;
    final String etaLine = hasRealEta
        ? 'Chegada ≈ ${DateFormat('HH:mm').format(routeComputedAt.add(Duration(seconds: totalDurationSeconds.round())))} • $totalStops paradas • ${totalWeight.toStringAsFixed(1)} kg'
        : '$totalStops paradas • ${totalWeight.toStringAsFixed(1)} kg • cálculo local';

    final nextIdx = _nextPendingIndex(stops);
    final isRouteInProgress = stops.any((s) => s.status == StopStatus.completed || s.status == StopStatus.inTransit);
    final allCompleted = stops.isNotEmpty && stops.every((s) => s.status == StopStatus.completed);

    final String buttonLabel = allCompleted
        ? 'Rota Concluída'
        : isRouteInProgress
            ? 'Continuar ${nextIdx + 1}/${stops.length}'
            : 'Iniciar Rota';

    // Dispara auto-scroll para a parada atual quando a rota estiver em andamento
    if (stops.isNotEmpty && isRouteInProgress && _lastAutoScrolledIndex != nextIdx) {
      _lastAutoScrolledIndex = nextIdx;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _autoScrollToCurrentStop(nextIdx, animate: true);
      });
    }

    return Container(
      decoration: BoxDecoration(
        color: sheetBg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border.all(color: sheetBorder, width: 1.2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.7 : 0.18),
            blurRadius: 20,
            offset: const Offset(0, -6),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (ctx, constraints) {
          // Altura natural máxima do cabeçalho (handle + busca + eta + título + botão + label)
          const double headerNatH = 232.0;
          final double availH = constraints.maxHeight;
          // Cabeçalho: no máximo headerNatH, no mínimo 0 (quando card minúsculo)
          final double headerH = availH.clamp(0.0, headerNatH);
          final double listH = (availH - headerH).clamp(0.0, availH);
          return Column(
            children: [
              // 1. CABEÇALHO FIXO: Arrastar aqui controla a altura do card; a lista de paradas rola independentemente
              SizedBox(
                height: headerH,
                child: ClipRect(
                  child: OverflowBox(
                    maxHeight: double.infinity,
                    alignment: Alignment.topCenter,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onVerticalDragUpdate: _onSheetDragUpdate,
                      onVerticalDragEnd: _onSheetDragEnd,
                      child: Container(
              color: sheetBg,
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Center(
                    child: GestureDetector(
                      onTap: _toggleSheetSize,
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 30),
                        color: Colors.transparent,
                        child: Container(
                          width: 38,
                          height: 4.5,
                          decoration: BoxDecoration(
                            color: sheetBorder,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),



          // Search bar com autocomplete interativo (estilo Circuit / Google Maps)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            decoration: BoxDecoration(
              color: inputBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: _searchFocus.hasFocus ? AppColors.circuitBlueGlow : inputBorder,
                width: _searchFocus.hasFocus ? 1.5 : 1.0,
              ),
            ),
            child: Row(
              children: [
                Icon(Icons.search, color: subColor, size: 22),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _searchCtrl,
                    focusNode: _searchFocus,
                    onChanged: _onInlineSearch,
                    style: TextStyle(
                      color: titleColor,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                    decoration: InputDecoration(
                      hintText: 'Adicionar parada (ex: Rua Augusta, 100)...',
                      hintStyle: TextStyle(
                        color: subColor,
                        fontSize: 13,
                        fontWeight: FontWeight.w400,
                      ),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                  ),
                ),
                if (_isSearching) ...[
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.circuitBlueGlow,
                    ),
                  ),
                  const SizedBox(width: 6),
                ] else if (_searchCtrl.text.isNotEmpty) ...[
                  IconButton(
                    tooltip: 'Limpar busca',
                    icon: Icon(Icons.close, color: subColor, size: 18),
                    visualDensity: VisualDensity.compact,
                    onPressed: _collapseSearch,
                  ),
                ],
                IconButton(
                  tooltip: 'Scanner de Carga',
                  icon: const Icon(Icons.qr_code_scanner, color: AppColors.circuitBlueGlow, size: 22),
                  onPressed: _openScanner,
                ),
                IconButton(
                  tooltip: 'Mais opções',
                  icon: Icon(Icons.more_vert, color: subColor, size: 20),
                  onPressed: () => _openOptionsMenu(context, isDark, stops),
                ),
              ],
            ),
          ),

          // ── Resultado de busca por código de barras ──────────────────────
          if (_packageSearchHit != null) ...[
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                color: isDark ? AppColors.carbonSurfaceElevated : Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isDark ? AppColors.carbonBorder : AppColors.lightBorder,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.08),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Cabeçalho: ícone + parada
                  Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: const Color(0xFF2563EB).withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(
                          Icons.inventory_2_outlined,
                          color: Color(0xFF2563EB),
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Parada ${_packageSearchHit!.sequenceIndex + 1}',
                              style: TextStyle(
                                color: const Color(0xFF2563EB),
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.4,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _packageSearchHit!.recipientName,
                              style: TextStyle(
                                color: titleColor,
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      // Badge de status
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: _packageSearchHit!.status == StopStatus.completed
                              ? Colors.green.withValues(alpha: 0.15)
                              : const Color(0xFF2563EB).withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          _packageSearchHit!.status == StopStatus.completed
                              ? 'Entregue'
                              : _packageSearchHit!.status == StopStatus.inTransit
                                  ? 'Em trânsito'
                                  : 'Pendente',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: _packageSearchHit!.status ==
                                    StopStatus.completed
                                ? Colors.green
                                : const Color(0xFF2563EB),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  // Divider
                  Divider(
                    height: 1,
                    color: isDark
                        ? AppColors.carbonBorderSubtle
                        : AppColors.lightBorderSubtle,
                  ),
                  const SizedBox(height: 10),
                  // Endereço
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.location_on_outlined,
                          size: 16, color: subColor),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          _packageSearchHit!.address,
                          style: TextStyle(
                            color: subColor,
                            fontSize: 12,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                  // Código de barras
                  if (_packageSearchHitPkg != null) ...[
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(Icons.qr_code, size: 16, color: subColor),
                        const SizedBox(width: 6),
                        Text(
                          _packageSearchHitPkg!.barcode,
                          style: TextStyle(
                            color: subColor,
                            fontSize: 12,
                            fontFamily: 'monospace',
                          ),
                        ),
                        if (_packageSearchHit!.packages.length > 1) ...[
                          const SizedBox(width: 6),
                          Text(
                            '(+${_packageSearchHit!.packages.length - 1} vol.)',
                            style: TextStyle(
                              color: subColor.withValues(alpha: 0.7),
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],

          if (_searchResults.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              decoration: BoxDecoration(
                color: isDark ? AppColors.carbonSurfaceElevated : AppColors.lightSurfaceElevated,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: isDark ? AppColors.carbonBorder : AppColors.lightBorder),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.35 : 0.08),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (int rIdx = 0; rIdx < _searchResults.length; rIdx++) ...[
                    if (rIdx > 0)
                      Divider(
                        height: 1,
                        color: isDark ? AppColors.carbonBorderSubtle : AppColors.lightBorderSubtle,
                      ),
                    ListTile(
                      dense: true,
                      leading: const Icon(
                        Icons.add_location_alt_outlined,
                        color: AppColors.circuitBlueGlow,
                        size: 22,
                      ),
                      title: Text(
                        _extractShortName(_searchResults[rIdx].displayName),
                        style: TextStyle(
                          color: titleColor,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        _searchResults[rIdx].displayName,
                        style: TextStyle(
                          color: subColor,
                          fontSize: 11,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: AppColors.circuitGreen.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: AppColors.circuitGreen.withValues(alpha: 0.5)),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.add, size: 14, color: AppColors.circuitGreen),
                            SizedBox(width: 4),
                            Text(
                              'Adicionar',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: AppColors.circuitGreen,
                              ),
                            ),
                          ],
                        ),
                      ),
                      onTap: () => _addFromSearchResult(_searchResults[rIdx]),
                    ),
                  ],
                  Divider(
                    height: 1,
                    color: isDark ? AppColors.carbonBorderSubtle : AppColors.lightBorderSubtle,
                  ),
                  InkWell(
                    onTap: () {
                      _collapseSearch();
                      _openAddStop();
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.edit_note, size: 16, color: subColor),
                          const SizedBox(width: 6),
                          Text(
                            'Formulário completo com volumes detalhados',
                            style: TextStyle(
                              color: subColor,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 14),

          Text(
            etaLine,
            style: TextStyle(
              color: subColor,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),

          Row(
            children: [
              Expanded(
                child: Text(
                  currentVersion?.label.toUpperCase() ?? 'MANIFESTO OPERACIONAL',
                  style: TextStyle(
                    color: titleColor,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.3,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppColors.circuitBlue.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '$loadedCount/$totalCount BIPADOS',
                  style: const TextStyle(
                    color: AppColors.circuitBlueGlow,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
                  // Botão de Ação Rápida: Iniciar Rota ou Continuar x/y
                  if (stops.isNotEmpty && !_isNavigating) ...[
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () {
                          if (allCompleted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('Todas as entregas deste manifesto já foram concluídas!'),
                                backgroundColor: AppColors.circuitGreen,
                              ),
                            );
                            return;
                          }
                          final idx = _nextPendingIndex(stops);
                          setState(() => _selectedStopIndex = idx);
                          _startInAppNavigation(stops[idx], forceFollow: true);
                        },
                        icon: const Icon(Icons.navigation_rounded, size: 18),
                        label: Text(
                          buttonLabel,
                          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF2563EB),
                          foregroundColor: Colors.white,
                          elevation: 0,
                          minimumSize: const Size(double.infinity, 46),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      ),
                    ),
                  ],

                  const SizedBox(height: 10),

                  Text(
                    'ITINERÁRIO EM SEQUÊNCIA (LIFO)',
                    style: TextStyle(
                      color: mutedColor,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.0,
                    ),
                  ),
                ],
              ),
                    ),
                  ),
                ),
              ),
            ),

              // 2. LISTA DE ROTAS INDEPENDENTE (ROLA 100% INDEPENDENTE DO CARD)
              SizedBox(
                height: listH,
            child: ListView.builder(
              controller: _routesScrollController,
              cacheExtent: 600,
              padding: EdgeInsets.fromLTRB(
                16,
                4,
                16,
                24 + MediaQuery.of(context).padding.bottom,
              ),
              itemCount: stops.length,
              itemBuilder: (context, i) {
                return RepaintBoundary(
                  key: ValueKey('rpb_${stops[i].id}_${stops[i].status.name}'),
                  child: Dismissible(
                  key: ValueKey('stop_${stops[i].id}_${stops[i].status.name}'),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    margin: const EdgeInsets.only(bottom: 6),
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    decoration: BoxDecoration(
                      color: AppColors.circuitRed,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    alignment: Alignment.centerRight,
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.delete_outline, color: Colors.white, size: 20),
                        SizedBox(width: 6),
                        Text(
                          'Remover',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  confirmDismiss: (_) => _confirmRemoveDismiss(stops[i]),
                  child: _buildTimelineStopItem(
                    isDark: isDark,
                    stop: stops[i],
                    timeLabel: _stopTimeLabel(
                      index: i,
                      stop: stops[i],
                      arrivalOffsets: arrivalOffsets,
                      routeComputedAt: routeComputedAt,
                      isOnlineRouting: isOnlineRouting,
                    ),
                    isLast: i == stops.length - 1,
                    isSelected: i == _selectedStopIndex,
                    onTap: () {
                      setState(() {
                        _selectedStopIndex = i;
                        _isNavigating = true;
                        _followGps = false;
                        _courseUp = false;
                      });
                      try {
                        _mapController.rotate(0);
                      } catch (_) {}
                      _mapController.move(LatLng(stops[i].latitude, stops[i].longitude), 15.0);
                      _animateSheetTo(0.28);
                    },
                    onRemove: () => _confirmRemoveStop(stops[i]),
                  ),
                ));
              },
              ),
            ),
          ],
        );
        },
      ),
    );
}

  String _stopTimeLabel({
    required int index,
    required DeliveryStop stop,
    required List<double> arrivalOffsets,
    required DateTime? routeComputedAt,
    required bool isOnlineRouting,
  }) {
    if (isOnlineRouting &&
        routeComputedAt != null &&
        arrivalOffsets.length > index) {
      final eta = routeComputedAt
          .add(Duration(seconds: arrivalOffsets[index].round()));
      return DateFormat('HH:mm').format(eta);
    }
    return '#${stop.sequenceIndex}';
  }


  Widget _buildTimelineStopItem({
    required bool isDark,
    required DeliveryStop stop,
    required String timeLabel,
    required bool isLast,
    required bool isSelected,
    required VoidCallback onTap,
    required VoidCallback onRemove,
  }) {
    final isCompleted = stop.status == StopStatus.completed;
    final isFailed = stop.status == StopStatus.failed;
    final titleColor = isDark ? AppColors.textWhite : AppColors.lightTextPrimary;
    final subColor = isDark ? AppColors.textSlate : AppColors.lightTextSecondary;
    final mutedColor = isDark ? AppColors.textMuted : AppColors.lightTextMuted;
    final chipBg = isDark ? AppColors.carbonSurfaceInput : AppColors.lightSurfaceElevated;
    final chipBorder = isDark ? AppColors.carbonBorder : AppColors.lightBorder;
    final selectedBg = isDark ? AppColors.carbonSurfaceElevated : AppColors.lightSurfaceElevated;
    final notes = stop.notes?.trim();

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: isSelected ? selectedBg : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: isSelected ? Border.all(color: AppColors.circuitBlueGlow, width: 1.2) : null,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 42,
                child: Text(
                  timeLabel,
                  style: TextStyle(
                    color: isCompleted ? mutedColor : subColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),

              Column(
                children: [
                  Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: isCompleted
                          ? const Color(0xFF16A34A)
                          : (isFailed ? const Color(0xFFDC2626) : chipBg),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isCompleted
                            ? const Color(0xFF16A34A)
                            : (isFailed ? const Color(0xFFDC2626) : AppColors.circuitBlueGlow),
                        width: 2,
                      ),
                    ),
                    child: Center(
                      child: Text(
                        '${stop.sequenceIndex}',
                        style: TextStyle(
                          color: (isCompleted || isFailed)
                              ? Colors.white
                              : (isDark ? Colors.white : AppColors.circuitBlue),
                          fontSize: 12,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ),
                  if (!isLast)
                    Container(
                      width: 2,
                      height: 40,
                      color: chipBorder,
                    ),
                ],
              ),

              const SizedBox(width: 12),

              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            stop.recipientName,
                            style: TextStyle(
                              color: isCompleted ? subColor : titleColor,
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              decoration: isCompleted ? TextDecoration.lineThrough : null,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (stop.packages.isNotEmpty) ...[
                          Text(
                            '${stop.packages.length} vol',
                            style: TextStyle(
                              color: mutedColor,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(width: 6),
                        ],
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: isCompleted
                                ? const Color(0xFF16A34A)
                                : (isFailed ? const Color(0xFFDC2626) : chipBg),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: isCompleted
                                  ? const Color(0xFF16A34A)
                                  : (isFailed ? const Color(0xFFDC2626) : chipBorder),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'ID ${stop.sequenceIndex}',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800,
                                  color: (isCompleted || isFailed)
                                      ? Colors.white
                                      : titleColor,
                                ),
                              ),
                              if (isCompleted) ...[
                                const SizedBox(width: 3),
                                const Icon(Icons.check, size: 10, color: Colors.white),
                              ],
                              if (isFailed) ...[
                                const SizedBox(width: 3),
                                const Icon(Icons.close, size: 10, color: Colors.white),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(width: 4),
                        GestureDetector(
                          onTap: onRemove,
                          child: Padding(
                            padding: const EdgeInsets.all(2),
                            child: Icon(Icons.close, size: 16, color: mutedColor),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      stop.address,
                      style: TextStyle(color: subColor, fontSize: 12),
                    ),
                    // Badge de código de rastreio
                    Builder(builder: (context) {
                      final barcodes = stop.packages
                          .map((p) => p.barcode.trim())
                          .where((b) => b.isNotEmpty)
                          .toList();
                      if (barcodes.isEmpty) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.only(top: 5),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                          decoration: BoxDecoration(
                            color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1),
                              width: 1,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.qr_code_2_rounded,
                                size: 13,
                                color: isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB),
                              ),
                              const SizedBox(width: 5),
                              Text(
                                'RASTREIO: ',
                                style: TextStyle(
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.w900,
                                  color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                                  letterSpacing: 0.4,
                                ),
                              ),
                              Flexible(
                                child: Text(
                                  barcodes.join(' • '),
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w700,
                                    fontFamily: 'monospace',
                                    color: isDark ? Colors.white : const Color(0xFF0F172A),
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
                    if (notes != null && notes.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                        decoration: BoxDecoration(
                          color: isDark ? AppColors.carbonSurfaceInput : AppColors.lightSurfaceElevated,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: isDark ? AppColors.carbonBorder : AppColors.lightBorder,
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              Icons.article_outlined,
                              size: 13,
                              color: isDark ? AppColors.circuitBlueGlow : AppColors.circuitBlue,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                notes,
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w500,
                                  color: isDark ? AppColors.textSlate : AppColors.lightTextSecondary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      );
  }

  /// HUD de navegação superior estilo Waze (na cor azul).
  /// Exibe dados reais da parada alvo (número, destinatário, endereço e distância GPS).
  /// Aparece temporariamente ao iniciar ou aproximar e some com fade suave.
  Widget _buildManeuverHud({DeliveryStop? targetStop}) {
    if (targetStop == null) return const SizedBox.shrink();

    String distanceText = '';
    if (_currentLocation != null) {
      final meters = LifoCalculator.calculateDistanceMeters(
        _currentLocation!.latitude,
        _currentLocation!.longitude,
        targetStop.latitude,
        targetStop.longitude,
      );
      if (meters < 1000) {
        distanceText = '${meters.round()} m';
      } else {
        distanceText = '${(meters / 1000.0).toStringAsFixed(1)} km';
      }
    }

    return Container(
      constraints: const BoxConstraints(minHeight: 46),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFF1D4ED8),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
        border: Border.all(
          color: const Color(0xFF60A5FA),
          width: 1.2,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.22),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.navigation_rounded,
              color: Colors.white,
              size: 20,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'PARADA #${targetStop.sequenceIndex}',
                      style: const TextStyle(
                        color: Color(0xFFBFDBFE),
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.4,
                      ),
                    ),
                    if (distanceText.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          distanceText,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 1),
                Text(
                  targetStop.recipientName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (targetStop.address.isNotEmpty) ...[
                  const SizedBox(height: 1),
                  Text(
                    targetStop.address,
                    style: const TextStyle(
                      color: Color(0xFFBFDBFE),
                      fontSize: 10.5,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActiveNavigationCard({
    required bool isDark,
    required DeliveryStop stop,
    required int currentIndex,
    required int totalStops,
    required String timeLabel,
    required VoidCallback onNavigate,
    required VoidCallback onNext,
    VoidCallback? onPrevious,
    required VoidCallback onMarkFailed,
    required VoidCallback onMarkCompleted,
    required VoidCallback onUndo,
    required VoidCallback onClose,
  }) {
    final titleColor = isDark ? AppColors.textWhite : AppColors.lightTextPrimary;
    final subColor = isDark ? AppColors.textSlate : AppColors.lightTextSecondary;
    final cardBg = isDark ? AppColors.carbonSurface : AppColors.lightSurfaceElevated;
    final cardBorder = isDark ? AppColors.carbonBorder : AppColors.lightBorder;
    final notes = stop.notes?.trim();
    final isFinalized = stop.status == StopStatus.completed || stop.status == StopStatus.failed;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: AppColors.circuitBlueGlow.withValues(alpha: 0.6),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.circuitBlue.withValues(alpha: isDark ? 0.25 : 0.12),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Top Row: Status dot + Sequence/ETA + Close button
          Row(
            children: [
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: stop.status == StopStatus.completed
                      ? const Color(0xFF16A34A)
                      : (stop.status == StopStatus.failed
                          ? const Color(0xFFDC2626)
                          : const Color(0xFF2563EB)),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${currentIndex + 1}/$totalStops, $timeLabel',
                style: TextStyle(
                  color: titleColor,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.2,
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: stop.status == StopStatus.completed
                      ? const Color(0xFF16A34A)
                      : (stop.status == StopStatus.failed
                          ? const Color(0xFFDC2626)
                          : const Color(0xFF2563EB)),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  stop.status == StopStatus.completed
                      ? 'ENTREGUE'
                      : (stop.status == StopStatus.failed
                          ? 'NÃO ENTREGUE'
                          : 'ROTA EM ANDAMENTO'),
                  style: const TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            const Spacer(),
            InkWell(
              onTap: onClose,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(Icons.close, size: 18, color: subColor),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),

        // Recipient & Address
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    stop.recipientName,
                    style: TextStyle(
                      color: titleColor,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    stop.address,
                    style: TextStyle(
                      color: subColor,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),

        // Código de Rastreio dos Pacotes (Obrigatório e Destaque)
        Builder(builder: (context) {
          final barcodes = stop.packages
              .map((p) => p.barcode.trim())
              .where((b) => b.isNotEmpty)
              .toList();
          final trackingLabel = barcodes.isNotEmpty
              ? barcodes.join(' • ')
              : 'ID #${stop.sequenceIndex} (Sem código vinculado)';

          return Container(
            width: double.infinity,
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1),
                width: 1.2,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.qr_code_2_rounded,
                  size: 17,
                  color: isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB),
                ),
                const SizedBox(width: 8),
                Text(
                  'RASTREIO:',
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w900,
                    color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                    letterSpacing: 0.6,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    trackingLabel,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      fontFamily: 'monospace',
                      color: isDark ? Colors.white : const Color(0xFF0F172A),
                      letterSpacing: 0.5,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (stop.packages.length > 1)
                  Container(
                    margin: const EdgeInsets.only(left: 6),
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2563EB).withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '${stop.packages.length} vols',
                      style: const TextStyle(
                        fontSize: 9.5,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF3B82F6),
                      ),
                    ),
                  ),
              ],
            ),
          );
        }),

          // Observações do manifesto (se houver)
          if (notes != null && notes.isNotEmpty) ...[
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: isDark ? AppColors.carbonSurfaceInput : AppColors.lightSurface,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: cardBorder),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.article_outlined,
                    size: 13,
                    color: isDark ? AppColors.circuitBlueGlow : AppColors.circuitBlue,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      notes,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        color: isDark ? AppColors.textSlate : AppColors.lightTextSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 10),

          // As Ações do Card
          Row(
            children: [
              Expanded(
                child: isFinalized
                    ? _buildStopActionButton(
                        isDark: isDark,
                        customBg: isDark ? const Color(0xFF0F172A) : Colors.black,
                        customBorder: isDark ? const Color(0xFF334155) : Colors.black,
                        customTextColor: Colors.white,
                        icon: const Icon(
                          Icons.undo_rounded,
                          size: 19,
                          color: Colors.white,
                        ),
                        label: 'Desfazer',
                        onTap: onUndo,
                      )
                    : _buildStopActionButton(
                        isDark: isDark,
                        isPrimary: true,
                        icon: const Icon(
                          Icons.navigation_rounded,
                          size: 18,
                          color: Colors.white,
                        ),
                        label: 'Navegar',
                        onTap: onNavigate,
                      ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _buildStopActionButton(
                  isDark: isDark,
                  icon: Icon(
                    Icons.redo_rounded,
                    size: 19,
                    color: isDark ? Colors.white70 : AppColors.lightTextSecondary,
                  ),
                  label: 'Próxima',
                  onTap: onNext,
                ),
              ),
              const SizedBox(width: 6),
              if (isFinalized)
                Expanded(
                  flex: 2,
                  child: _buildStopStatusVisualizer(
                    isDark: isDark,
                    isCompleted: stop.status == StopStatus.completed,
                  ),
                )
              else ...[
                Expanded(
                  child: _buildStopActionButton(
                    isDark: isDark,
                    isSelected: stop.status == StopStatus.failed,
                    selectedColor: const Color(0xFFDC2626),
                    icon: SizedBox(
                      width: 22,
                      height: 20,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Center(
                            child: Icon(
                              Icons.inventory_2_outlined,
                              size: 19,
                              color: isDark ? Colors.white70 : AppColors.lightTextSecondary,
                            ),
                          ),
                          Positioned(
                            right: -1,
                            bottom: -1,
                            child: Container(
                              width: 10,
                              height: 10,
                              decoration: const BoxDecoration(
                                color: Color(0xFFDC2626),
                                shape: BoxShape.circle,
                              ),
                              child: const Center(
                                child: Icon(
                                  Icons.close,
                                  size: 7,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    label: 'Não entreg...',
                    onTap: onMarkFailed,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: _buildStopActionButton(
                    isDark: isDark,
                    isSelected: stop.status == StopStatus.completed,
                    selectedColor: const Color(0xFF16A34A),
                    icon: SizedBox(
                      width: 22,
                      height: 20,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Center(
                            child: Icon(
                              Icons.inventory_2_outlined,
                              size: 19,
                              color: isDark ? Colors.white70 : AppColors.lightTextSecondary,
                            ),
                          ),
                          Positioned(
                            right: -1,
                            bottom: -1,
                            child: Container(
                              width: 10,
                              height: 10,
                              decoration: const BoxDecoration(
                                color: Color(0xFF43A047),
                                shape: BoxShape.circle,
                              ),
                              child: const Center(
                                child: Icon(
                                  Icons.check,
                                  size: 7,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    label: 'Entregue',
                    onTap: onMarkCompleted,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStopStatusVisualizer({
    required bool isDark,
    required bool isCompleted,
  }) {
    final color = isCompleted ? const Color(0xFF16A34A) : const Color(0xFFDC2626);
    final label = isCompleted ? 'Entregue' : 'Não entregue';
    final icon = isCompleted ? Icons.check_circle_rounded : Icons.cancel_rounded;

    return Container(
      height: 52,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(10),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: isDark ? 0.35 : 0.25),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 20, color: Colors.white),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: Colors.white,
                letterSpacing: 0.3,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStopActionButton({
    required bool isDark,
    required Widget icon,
    required String label,
    required VoidCallback onTap,
    bool isPrimary = false,
    bool isSelected = false,
    Color? selectedColor,
    Color? customBg,
    Color? customBorder,
    Color? customTextColor,
  }) {
    final bg = customBg ??
        (isPrimary
            ? const Color(0xFF2563EB)
            : (isSelected
                ? (selectedColor ?? const Color(0xFF2563EB))
                : (isDark ? AppColors.carbonSurfaceInput : AppColors.lightSurfaceElevated)));
    final border = customBorder ??
        (isPrimary
            ? const Color(0xFF2563EB)
            : (isSelected
                ? (selectedColor ?? const Color(0xFF2563EB))
                : (isDark ? AppColors.carbonBorder : AppColors.lightBorder)));
    final textColor = customTextColor ??
        (isPrimary || isSelected
            ? Colors.white
            : (isDark ? AppColors.textWhite : AppColors.lightTextPrimary));

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Ink(
          height: 52,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: border, width: isSelected || isPrimary ? 1.2 : 1.0),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              icon,
              const SizedBox(height: 3),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: textColor,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatCircuitDate(DateTime dt) {
    const months = ['jan.', 'fev.', 'mar.', 'abr.', 'mai.', 'jun.', 'jul.', 'ago.', 'set.', 'out.', 'nov.', 'dez.'];
    final day = dt.day.toString().padLeft(2, '0');
    final month = months[(dt.month - 1).clamp(0, 11)];
    return '$day de $month';
  }

  String _formatCircuitExpiry(DateTime dt) {
    const weekDays = ['seg.', 'ter.', 'qua.', 'qui.', 'sex.', 'sáb.', 'dom.'];
    const months = ['jan.', 'fev.', 'mar.', 'abr.', 'mai.', 'jun.', 'jul.', 'ago.', 'set.', 'out.', 'nov.', 'dez.'];
    final dayName = weekDays[(dt.weekday - 1).clamp(0, 6)];
    final day = dt.day;
    final month = months[(dt.month - 1).clamp(0, 11)];
    return 'Expira em $dayName $day de $month';
  }

  void _showHelpDialog(BuildContext ctx) {
    showDialog(
      context: ctx,
      builder: (dCtx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.help_outline, color: Color(0xFF2563EB)),
            SizedBox(width: 8),
            Text('Ajuda & Suporte', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          ],
        ),
        content: const Text(
          'O LIFO Logistics organiza suas rotas com otimização inteligente de descarregamento LIFO (Last-In, First-Out).\n\n'
          '• Importe seus manifestos CSV/TXT/Excel clicando em "+ Criar rota".\n'
          '• Sincronize com sua conta Google para salvar o histórico.\n'
          '• Acompanhe suas paradas diretamente pelo mapa interativo.',
          style: TextStyle(fontSize: 13, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx),
            child: const Text('Entendi', style: TextStyle(color: Color(0xFF2563EB), fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  Future<void> _renameRouteDialog(
    BuildContext ctx,
    ManifestVersion version,
    List<ManifestVersion> allRoutes,
  ) async {
    final isDark = Theme.of(ctx).brightness == Brightness.dark;
    final ctrl = TextEditingController(text: version.label);
    final newName = await showDialog<String>(
      context: ctx,
      builder: (dCtx) => AlertDialog(
        backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Renomear rota', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          style: TextStyle(color: isDark ? Colors.white : const Color(0xFF0F172A)),
          decoration: InputDecoration(
            hintText: 'Novo nome da rota',
            filled: true,
            fillColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF2563EB),
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(dCtx, ctrl.text.trim()),
            child: const Text('Salvar'),
          ),
        ],
      ),
    );
    if (newName != null && newName.isNotEmpty && mounted) {
      final conflict = allRoutes.any(
        (r) => r.id != version.id && r.label.trim().toLowerCase() == newName.toLowerCase(),
      );
      if (conflict) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Já existe uma rota com esse nome. Não é permitido rotas duplicadas.'),
            backgroundColor: AppColors.statusDanger,
            duration: Duration(seconds: 3),
          ),
        );
        return;
      }
      await ref.read(manifestControllerProvider.notifier).renameVersion(version.id, newName);
    }
  }

  Future<void> _confirmDeleteVersion(BuildContext ctx, ManifestVersion version) async {
    final confirm = await showDialog<bool>(
      context: ctx,
      builder: (dCtx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Excluir Versão?'),
        content: Text(
          'Deseja excluir permanentemente a versão "${version.label}"?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dCtx).pop(false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.statusDanger),
            onPressed: () => Navigator.of(dCtx).pop(true),
            child: const Text('Excluir Versão'),
          ),
        ],
      ),
    );
    if (confirm == true && mounted) {
      await ref.read(manifestControllerProvider.notifier).deleteVersion(version.id);
      if (mounted) {
        final current = ref.read(manifestControllerProvider).currentVersion;
        if (current == null || current.stops.isEmpty) {
          setState(() {
            _isNavigating = false;
            _courseUp = false;
            _selectedStopIndex = 0;
            _legPolyline = [];
            _lastLegTargetStopId = null;
          });
        } else {
          _fitToCurrentManifest();
        }
      }
    }
  }

  Future<void> _confirmClearManifestCascade(BuildContext ctx, ManifestVersion root) async {
    final confirm = await showDialog<bool>(
      context: ctx,
      builder: (dCtx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Limpar Manifesto Completo?'),
        content: Text(
          'Esta ação excluirá o manifesto "${root.label}" e todas as suas versões otimizadas em cascata.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dCtx).pop(false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppColors.statusDanger),
            onPressed: () => Navigator.of(dCtx).pop(true),
            child: const Text('Excluir Tudo em Cascata'),
          ),
        ],
      ),
    );
    if (confirm == true && mounted) {
      await ref.read(manifestControllerProvider.notifier).deleteManifestCascade(root.id);
      if (mounted) {
        setState(() {
          _expandedGroupIds.remove(root.id);
          _collapsedGroupIds.remove(root.id);
        });
        final current = ref.read(manifestControllerProvider).currentVersion;
        if (current == null || current.stops.isEmpty) {
          setState(() {
            _isNavigating = false;
            _courseUp = false;
            _selectedStopIndex = 0;
            _legPolyline = [];
            _lastLegTargetStopId = null;
          });
        } else {
          _fitToCurrentManifest();
        }
      }
    }
  }

  Widget _buildCircuitDrawer(BuildContext context, WidgetRef ref, dynamic currentVersion) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final authState = ref.watch(authControllerProvider);
    final user = authState.user;
    final manifestState = ref.watch(manifestControllerProvider);

    final drawerBg = isDark ? const Color(0xFF0F172A) : Colors.white;
    final cardBg = isDark ? const Color(0xFF1E293B) : const Color(0xFFEDF4FE);
    final titleColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
    final dividerColor = isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0);

    // Lista de rotas importadas
    final List<ManifestVersion> allRoutes = [];
    if (manifestState.currentVersion != null) {
      allRoutes.add(manifestState.currentVersion!);
    }
    for (final v in manifestState.versionHistory) {
      if (allRoutes.every((item) => item.id != v.id)) {
        allRoutes.add(v);
      }
    }

    return Drawer(
      width: MediaQuery.of(context).size.width * 0.84,
      backgroundColor: drawerBg,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── TOP PROFILE / ACCOUNT CARD (Estilo Circuit) ─────────────
            Container(
              color: cardBg,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Ícones de ação no topo direito: Ajuda (?) e Configurações (⚙)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: Icon(Icons.help_outline, size: 22, color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569)),
                        tooltip: 'Ajuda',
                        onPressed: () => _showHelpDialog(context),
                      ),
                      const SizedBox(width: 4),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        icon: Icon(Icons.settings_outlined, size: 22, color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF475569)),
                        tooltip: 'Minha Conta & Configurações',
                        onPressed: () => MyAccountScreen.open(context),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),

                  // Perfil do Usuário: Avatar, Nome, E-mail e Status
                  InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => MyAccountScreen.open(context),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          // Avatar circular com ilustração/gradiente
                          Container(
                            width: 54,
                            height: 54,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              gradient: const LinearGradient(
                                colors: [Color(0xFF34D399), Color(0xFF059669), Color(0xFF0284C7)],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFF059669).withValues(alpha: 0.25),
                                  blurRadius: 8,
                                  offset: const Offset(0, 3),
                                ),
                              ],
                            ),
                            child: Center(
                              child: Text(
                                user.name.isNotEmpty
                                    ? user.name
                                        .split(' ')
                                        .map((e) => e.isNotEmpty ? e[0] : '')
                                        .take(2)
                                        .join()
                                        .toUpperCase()
                                    : 'CL',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),

                          // Nome, email e plano
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  user.name,
                                  style: TextStyle(
                                    color: titleColor,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  user.email,
                                  style: TextStyle(
                                    color: subColor,
                                    fontSize: 12,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  '${user.plan} • ${_formatCircuitExpiry(user.expiresAt)}',
                                  style: TextStyle(
                                    color: isDark ? const Color(0xFF60A5FA) : const Color(0xFF64748B),
                                    fontSize: 11,
                                    fontWeight: FontWeight.w500,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Botão "⚡ Renovar" (como no Circuit)
                  SizedBox(
                    width: double.infinity,
                    height: 38,
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        backgroundColor: isDark ? const Color(0xFF0F172A) : Colors.white,
                        side: BorderSide(
                          color: isDark ? const Color(0xFF3B82F6) : const Color(0xFFBFDBFE),
                          width: 1.2,
                        ),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        elevation: 0,
                      ),
                      onPressed: () {
                        Navigator.pop(context); // Fecha o drawer antes de abrir a tela
                        SubscriptionRenewalScreen.open(context);
                      },
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.bolt, size: 18, color: Color(0xFF2563EB)),
                          SizedBox(width: 6),
                          Text(
                            'Renovar',
                            style: TextStyle(
                              color: Color(0xFF2563EB),
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // ── BOTÕES DE LOGIN GOOGLE E CRIAR CONTA ───────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Column(
                children: [
                  if (!user.isLoggedIn) ...[
                    GoogleSignInButton(
                      onPressed: () {
                        ref.read(authControllerProvider.notifier).loginWithGoogle();
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Conectado via Google!'),
                            backgroundColor: Color(0xFF2563EB),
                            duration: Duration(seconds: 2),
                          ),
                        );
                      },
                      text: 'Logar com o Google',
                      isLoading: authState.isLoading,
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        TextButton(
                          onPressed: () => LoginScreen.open(context),
                          child: const Text('Fazer Login', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                        ),
                        const Text('•', style: TextStyle(color: Color(0xFF94A3B8))),
                        TextButton(
                          onPressed: () => CreateAccountScreen.open(context),
                          child: const Text('Criar Conta', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                        ),
                      ],
                    ),
                  ] else ...[
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.logout, size: 16, color: AppColors.statusDanger),
                            label: const Text(
                              'Sair da conta',
                              style: TextStyle(color: AppColors.statusDanger, fontSize: 13, fontWeight: FontWeight.w600),
                            ),
                            style: OutlinedButton.styleFrom(
                              side: BorderSide(color: AppColors.statusDanger.withValues(alpha: 0.4)),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              padding: const EdgeInsets.symmetric(vertical: 10),
                            ),
                            onPressed: () async {
                              Navigator.of(context).pop();
                              await ref.read(authControllerProvider.notifier).logout();
                              if (context.mounted) {
                                LoginScreen.open(context);
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            Divider(color: dividerColor, height: 1),

            // ── SEÇÃO: INÍCIO DESTE MÊS (Lista de rotas importadas) ────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Text(
                'Início deste mês',
                style: TextStyle(
                  color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.2,
                ),
              ),
            ),

            // Lista das rotas agrupadas por manifesto original
            Expanded(
              child: Builder(
                builder: (ctx) {
                  if (allRoutes.isEmpty) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.route_outlined, size: 40, color: subColor.withValues(alpha: 0.35)),
                            const SizedBox(height: 8),
                            Text(
                              'Nenhuma rota importada',
                              style: TextStyle(color: subColor, fontSize: 13, fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Toque em "+ Criar rota" para importar seu primeiro manifesto.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: subColor.withValues(alpha: 0.7), fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                    );
                  }

                  final versionMap = {for (final v in allRoutes) v.id: v};

                  ManifestVersion findRoot(ManifestVersion v) {
                    var curr = v;
                    final visited = <String>{curr.id};
                    while (curr.parentVersionId != null && versionMap.containsKey(curr.parentVersionId)) {
                      final parent = versionMap[curr.parentVersionId!]!;
                      if (visited.contains(parent.id)) break;
                      visited.add(parent.id);
                      curr = parent;
                    }
                    return curr;
                  }

                  final Map<String, List<ManifestVersion>> grouped = {};
                  for (final v in allRoutes) {
                    final root = findRoot(v);
                    grouped.putIfAbsent(root.id, () => []).add(v);
                  }

                  final List<_RouteGroupData> groups = [];
                  for (final entry in grouped.entries) {
                    final ManifestVersion root = versionMap[entry.key] ?? entry.value.first;
                    final versions = List<ManifestVersion>.from(entry.value)
                      ..sort((a, b) => a.versionIndex.compareTo(b.versionIndex));
                    groups.add(_RouteGroupData(root: root, versions: versions));
                  }
                  groups.sort((a, b) => b.root.createdAt.compareTo(a.root.createdAt));

                  return ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    itemCount: groups.length,
                    itemBuilder: (ctx, idx) {
                      final group = groups[idx];
                      final childVersions = group.versions.where((v) => v.id != group.root.id).toList();
                      final hasVersions = childVersions.isNotEmpty;
                      final isRootActive = group.root.id == manifestState.currentVersion?.id;
                      final isGroupActive = group.versions.any((v) => v.id == manifestState.currentVersion?.id);

                      final isExpanded = _expandedGroupIds.contains(group.root.id) ||
                          (hasVersions && isGroupActive && !_collapsedGroupIds.contains(group.root.id));

                      return Container(
                        margin: const EdgeInsets.symmetric(vertical: 3),
                        decoration: BoxDecoration(
                          color: isRootActive
                              ? (isDark
                                  ? const Color(0xFF1E3A8A).withValues(alpha: 0.25)
                                  : const Color(0xFFEFF6FF))
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // ── CABEÇALHO DO MANIFESTO (Raiz / Original) ──
                            InkWell(
                              borderRadius: BorderRadius.circular(10),
                              onTap: () async {
                                if (hasVersions) {
                                  setState(() {
                                    if (isExpanded) {
                                      _expandedGroupIds.remove(group.root.id);
                                      _collapsedGroupIds.add(group.root.id);
                                    } else {
                                      _expandedGroupIds.add(group.root.id);
                                      _collapsedGroupIds.remove(group.root.id);
                                    }
                                  });
                                } else {
                                  Navigator.of(context).pop();
                                  if (!isRootActive) {
                                    await ref.read(manifestControllerProvider.notifier).revertToVersion(group.root.id);
                                  }
                                  _fitToCurrentManifest();
                                }
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                child: Row(
                                  children: [
                                    // Data da rota à esquerda (ex: "13 de out.")
                                    Text(
                                      _formatCircuitDate(group.root.createdAt),
                                      style: TextStyle(
                                        color: isRootActive
                                            ? const Color(0xFF3B82F6)
                                            : (isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B)),
                                        fontSize: 13,
                                        fontWeight: isRootActive ? FontWeight.w700 : FontWeight.w500,
                                      ),
                                    ),
                                    const SizedBox(width: 12),

                                    // Nome do manifesto base (ex: "Saco Grande")
                                    Expanded(
                                      child: Row(
                                        children: [
                                          Flexible(
                                            child: Text(
                                              group.root.label,
                                              style: TextStyle(
                                                color: isRootActive
                                                    ? const Color(0xFF1D4ED8)
                                                    : titleColor,
                                                fontSize: 13,
                                                fontWeight: FontWeight.w700,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          if (hasVersions) ...[
                                            const SizedBox(width: 6),
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                              decoration: BoxDecoration(
                                                color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
                                                borderRadius: BorderRadius.circular(10),
                                              ),
                                              child: Text(
                                                '${group.versions.length}',
                                                style: TextStyle(
                                                  fontSize: 10,
                                                  fontWeight: FontWeight.bold,
                                                  color: isDark ? Colors.white70 : const Color(0xFF475569),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),

                                    // Ícone de expandir se houver outras versões
                                    if (hasVersions)
                                      IconButton(
                                        icon: Icon(
                                          isExpanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                                          size: 20,
                                          color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
                                        ),
                                        visualDensity: VisualDensity.compact,
                                        padding: EdgeInsets.zero,
                                        constraints: const BoxConstraints(),
                                        onPressed: () {
                                          setState(() {
                                            if (isExpanded) {
                                              _expandedGroupIds.remove(group.root.id);
                                              _collapsedGroupIds.add(group.root.id);
                                            } else {
                                              _expandedGroupIds.add(group.root.id);
                                              _collapsedGroupIds.remove(group.root.id);
                                            }
                                          });
                                        },
                                      ),

                                    const SizedBox(width: 4),

                                    // Menu do Manifesto Original (Raiz)
                                    PopupMenuButton<String>(
                                      icon: Icon(
                                        Icons.more_vert,
                                        size: 18,
                                        color: isRootActive
                                            ? const Color(0xFF3B82F6)
                                            : (isDark ? const Color(0xFF94A3B8) : const Color(0xFF94A3B8)),
                                      ),
                                      tooltip: 'Opções do manifesto',
                                      color: isDark ? const Color(0xFF1E293B) : Colors.white,
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                      onSelected: (val) async {
                                        if (val == 'carregar') {
                                          Navigator.of(context).pop();
                                          if (!isRootActive) {
                                            await ref.read(manifestControllerProvider.notifier).revertToVersion(group.root.id);
                                          }
                                          _fitToCurrentManifest();
                                        } else if (val == 'renomear') {
                                          _renameRouteDialog(context, group.root, allRoutes);
                                        } else if (val == 'limpar_cascata') {
                                          _confirmClearManifestCascade(context, group.root);
                                        }
                                      },
                                      itemBuilder: (mCtx) => [
                                        const PopupMenuItem(
                                          value: 'carregar',
                                          child: Row(
                                            children: [
                                              Icon(Icons.map_outlined, size: 18, color: Color(0xFF2563EB)),
                                              SizedBox(width: 8),
                                              Text('Carregar Rota', style: TextStyle(fontSize: 13)),
                                            ],
                                          ),
                                        ),
                                        const PopupMenuItem(
                                          value: 'renomear',
                                          child: Row(
                                            children: [
                                              Icon(Icons.edit_outlined, size: 18),
                                              SizedBox(width: 8),
                                              Text('Renomear', style: TextStyle(fontSize: 13)),
                                            ],
                                          ),
                                        ),
                                        const PopupMenuItem(
                                          value: 'limpar_cascata',
                                          child: Row(
                                            children: [
                                              Icon(Icons.delete_sweep_outlined, size: 18, color: AppColors.statusDanger),
                                              SizedBox(width: 8),
                                              Text('Limpar Manifesto', style: TextStyle(fontSize: 13, color: AppColors.statusDanger, fontWeight: FontWeight.w600)),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),

                            // ── VERSÕES OTIMIZADAS FILHAS (Agrupadas dentro do manifesto) ──
                            if (hasVersions && isExpanded) ...[
                              Padding(
                                padding: const EdgeInsets.only(left: 20, right: 8, bottom: 6),
                                child: Column(
                                  children: [
                                    for (final v in childVersions) ...[
                                      Builder(builder: (c) {
                                        final isChildActive = v.id == manifestState.currentVersion?.id;
                                        return Container(
                                          margin: const EdgeInsets.symmetric(vertical: 2),
                                          decoration: BoxDecoration(
                                            color: isChildActive
                                                ? (isDark ? const Color(0xFF1E3A8A).withValues(alpha: 0.35) : const Color(0xFFDBEAFE))
                                                : (isDark ? const Color(0xFF1E293B).withValues(alpha: 0.6) : const Color(0xFFF8FAFC)),
                                            borderRadius: BorderRadius.circular(8),
                                            border: Border.all(
                                              color: isChildActive ? const Color(0xFF3B82F6) : Colors.transparent,
                                              width: 1,
                                            ),
                                          ),
                                          child: InkWell(
                                            borderRadius: BorderRadius.circular(8),
                                            onTap: () async {
                                              Navigator.of(context).pop();
                                              if (!isChildActive) {
                                                await ref.read(manifestControllerProvider.notifier).revertToVersion(v.id);
                                              }
                                              _fitToCurrentManifest();
                                            },
                                            child: Padding(
                                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                              child: Row(
                                                children: [
                                                  Icon(
                                                    Icons.subdirectory_arrow_right,
                                                    size: 16,
                                                    color: isChildActive ? const Color(0xFF3B82F6) : subColor,
                                                  ),
                                                  const SizedBox(width: 8),
                                                  Expanded(
                                                    child: Text(
                                                      v.label,
                                                      style: TextStyle(
                                                        color: isChildActive ? const Color(0xFF1D4ED8) : titleColor,
                                                        fontSize: 12.5,
                                                        fontWeight: isChildActive ? FontWeight.w700 : FontWeight.w500,
                                                      ),
                                                      maxLines: 1,
                                                      overflow: TextOverflow.ellipsis,
                                                    ),
                                                  ),
                                                  // Menu exclusivo das novas versões: apenas Renomear e Excluir
                                                  PopupMenuButton<String>(
                                                    icon: Icon(
                                                      Icons.more_vert,
                                                      size: 16,
                                                      color: isChildActive ? const Color(0xFF3B82F6) : subColor,
                                                    ),
                                                    tooltip: 'Opções da versão',
                                                    color: isDark ? const Color(0xFF1E293B) : Colors.white,
                                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                                    onSelected: (val) {
                                                      if (val == 'renomear') {
                                                        _renameRouteDialog(context, v, allRoutes);
                                                      } else if (val == 'excluir') {
                                                        _confirmDeleteVersion(context, v);
                                                      }
                                                    },
                                                    itemBuilder: (mCtx) => [
                                                      const PopupMenuItem(
                                                        value: 'renomear',
                                                        child: Row(
                                                          children: [
                                                            Icon(Icons.edit_outlined, size: 16),
                                                            SizedBox(width: 8),
                                                            Text('Renomear', style: TextStyle(fontSize: 13)),
                                                          ],
                                                        ),
                                                      ),
                                                      const PopupMenuItem(
                                                        value: 'excluir',
                                                        child: Row(
                                                          children: [
                                                            Icon(Icons.delete_outline, size: 16, color: AppColors.statusDanger),
                                                            SizedBox(width: 8),
                                                            Text('Excluir', style: TextStyle(fontSize: 13, color: AppColors.statusDanger)),
                                                          ],
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        );
                                      }),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
            ),

            // ── BOTÃO INFERIOR "+ CRIAR ROTA" (Estilo Circuit) ─────────────
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: drawerBg,
                border: Border(top: BorderSide(color: dividerColor)),
              ),
              child: SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2563EB),
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: () {
                    Navigator.of(context).pop();
                    _openImport();
                  },
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.add, size: 20, color: Colors.white),
                      SizedBox(width: 8),
                      Text(
                        'Criar rota',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RouteGroupData {
  final ManifestVersion root;
  final List<ManifestVersion> versions;

  const _RouteGroupData({required this.root, required this.versions});
}
