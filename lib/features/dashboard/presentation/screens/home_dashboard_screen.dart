import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import '../../../../core/layout/map_split_layout.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/models/route_step.dart';
import '../../../../core/utils/lifo_calculator.dart';
import '../../../../core/utils/cpf_validator.dart';
import '../../../route_manifest/domain/models/delivery_stop.dart';
import '../../../route_manifest/domain/models/package_item.dart';
import '../../../route_manifest/domain/models/spatial_slot.dart';
import '../../../route_manifest/presentation/manifest_controller.dart';
import '../../../cargo_scanner/presentation/screens/cargo_scanner_screen.dart';
import '../../../vehicle_load/presentation/screens/vehicle_bay_screen.dart';
import '../../../vehicle_load/data/slot_names.dart';
import '../../../route_manifest/presentation/screens/add_stop_sheet.dart';
import '../../../route_manifest/presentation/screens/import_manifest_sheet.dart';
import '../../../route_manifest/presentation/screens/import_success_dialog.dart';
import '../../../navigation_map/presentation/widgets/logistics_map_canvas.dart';
import '../../../../core/services/geocoding_service.dart';
import '../../../../core/services/hybrid_routing_service.dart';
import '../../../../core/services/notification_service.dart';
import '../../../../core/services/voice_guidance.dart';
import '../../../route_manifest/domain/models/manifest_version.dart';
import '../../../auth/presentation/controllers/auth_controller.dart';
import '../../../auth/presentation/screens/create_account_screen.dart';
import '../../../auth/presentation/screens/my_account_screen.dart';
import '../../../auth/presentation/screens/subscription_renewal_screen.dart';
import '../../../auth/presentation/screens/login_screen.dart';
import '../../../auth/presentation/screens/legal_document_screen.dart';
import '../../../auth/presentation/widgets/google_sign_in_button.dart';
import '../../../onboarding/data/tutorial_prefs.dart';
import '../../../onboarding/presentation/widgets/coach_tutorial.dart';
import '../../../offline_maps/presentation/screens/offline_maps_screen.dart';
import '../../../../core/services/offline_map_service.dart';
import '../../../../core/network/connectivity_service.dart';
import '../../../../core/network/net_guard.dart';
import '../../../../core/services/app_update_service.dart';

/// Resultado da validação QR + GPS do card de navegação.
enum _QrCheck { none, ok, far, other, unknown, noGps }

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
  // Card com PISO DINÂMICO = altura exata do cabeçalho fixo (handle +
  // busca + eta + título + botão ≈ 232px): pode levantar até a tela cheia
  // (0.94), mas nunca desce a ponto de cortar o botão Iniciar/Continuar.
  // Pedido de uso em campo. Fração = px / altura da tela (qualquer aparelho).
  static const double _sheetHeaderPx = 232.0;
  // Estado vazio (sem manifesto): ícone + textos + 2 botões ≈ 340px.
  static const double _sheetEmptyPx = 344.0;
  static const double _sheetMaxExtent = 0.94;
  double _sheetExtent = 0.44;
  bool _sheetTouched = false;
  // Altura de referência do conteúdo atual (cheio = com rota, vazio = vazio).
  // Atualizada a cada build, antes de qualquer gesto.
  double _sheetFloorPx = _sheetHeaderPx;

  /// Menor altura permitida, em fração da tela: conteúdo fixo inteiro
  /// visível (com rota = cabeçalho + botão; vazio = os 2 botões).
  double _sheetFloor() {
    final h = MediaQuery.of(context).size.height;
    if (h <= 0) return 0.44;
    return ((_sheetFloorPx + 4) / h).clamp(0.28, 0.62);
  }
  late final ValueNotifier<double> _sheetExtentNotifier = ValueNotifier<double>(_sheetExtent);
  late final AnimationController _sheetAnimationController;
  Animation<double>? _sheetAnimation;

  void _animateSheetTo(double targetExtent) {
    if (!mounted) return;
    targetExtent = targetExtent.clamp(_sheetFloor(), _sheetMaxExtent);
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
    _sheetTouched = true;
    final screenHeight = MediaQuery.of(context).size.height;
    if (screenHeight <= 0) return;
    final delta = -details.delta.dy / screenHeight;
    _sheetExtent =
        (_sheetExtent + delta).clamp(_sheetFloor(), _sheetMaxExtent);
    _sheetExtentNotifier.value = _sheetExtent;
  }

  void _onSheetDragEnd(DragEndDetails details) {
    final floor = _sheetFloor();
    final velocity = details.primaryVelocity ?? 0;
    double target = floor;
    if (velocity < -250) {
      target = _sheetMaxExtent;
    } else if (velocity > 250) {
      target = floor;
    } else {
      target = _sheetExtent > 0.68 ? _sheetMaxExtent : floor;
    }
    _animateSheetTo(target);
  }

  void _toggleSheetSize() {
    _sheetTouched = true;
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

  // ── GPS granular (Fase 1a perf): o stream atualiza estes notifiers a
  // cada fix SEM setState na tela. Só pin do mapa, HUD e pílula de
  // velocidade ouvem (subárvores minúsculas); lista/marcadores/polyline
  // só rebuildam em mudança de dado (rota, status, seleção).
  final ValueNotifier<LatLng?> _livePin = ValueNotifier<LatLng?>(null);
  final ValueNotifier<double?> _liveHeading = ValueNotifier<double?>(null);
  final ValueNotifier<int> _gpsTick = ValueNotifier<int>(0);

  /// Publica um fix de GPS: atualiza campos + notifica ouvintes granulares.
  /// Não dá setState — quem precisa de rebuild total chama por conta própria.
  void _publishGpsFix(LatLng pos, {double? speedKmh, double? heading}) {
    _currentLocation = pos;
    if (speedKmh != null) _speedKmh = speedKmh;
    if (heading != null && heading >= 0 && heading <= 360) {
      _heading = heading;
    }
    _livePin.value = pos;
    if (_heading != null) _liveHeading.value = _heading;
    _gpsTick.value++;
  }

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
    if (stops.isEmpty) return;
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
          _scannedStop = null;
          _scannedBarcode = null;
          _verifyResult = _QrCheck.none;
        });
        if (nextIdx < stops.length && stops[nextIdx].status == StopStatus.pending) {
          ref.read(manifestControllerProvider.notifier).updateStopStatus(
            stops[nextIdx].id,
            StopStatus.inTransit,
          );
        }
        if (nextIdx < stops.length) {
          _startInAppNavigation(stops[nextIdx]);
        }
        _animateCardDragTo(0.0, duration: const Duration(milliseconds: 220), curve: Curves.easeOutCubic);
      });
    } else {
      _animateCardDragTo(0.0, duration: const Duration(milliseconds: 240), curve: Curves.easeOutBack);
    }
  }

  void _goToPreviousStop(List<DeliveryStop> stops) {
    if (stops.isEmpty) return;
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
          _scannedStop = null;
          _scannedBarcode = null;
          _verifyResult = _QrCheck.none;
        });
        if (prevIdx < stops.length) {
          _startInAppNavigation(stops[prevIdx]);
        }
        _animateCardDragTo(0.0, duration: const Duration(milliseconds: 220), curve: Curves.easeOutCubic);
      });
    } else {
      _animateCardDragTo(0.0, duration: const Duration(milliseconds: 240), curve: Curves.easeOutBack);
    }
  }
  StreamSubscription<Position>? _positionSub;
  bool _followGps = true;
  // Recentralizar automático (seta azul): ARMADO = fica azul p/ sempre até
  // tocar de novo. Mexer no mapa só solta a câmera por alguns segundos e
  // ela volta sozinha p/ trás do cursor. Separado de _followGps/_courseUp,
  // que são o estado transitório (seguindo agora ou câmera livre).
  bool _autoRecenterArmed = false;
  static const _kAutoRecenterDelay = Duration(seconds: 6);
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

  // Turn-by-turn do OSRM p/ o HUD estilo Waze (curva/rotatória + km de rua).
  List<RouteStep> _legSteps = [];
  List<int> _legStepIndices = [];   // índice na polyline de cada step
  List<double> _legCumMeters = [];  // distância acumulada de rua por ponto
  int _legClosestIdx = 0;           // ponto da polyline mais perto do GPS
  double _legRemainingMeters = -1;  // rua restante até a parada (-1 = sem dado)

  // HUD do topo estilo Waze (aparece uns segundos e some; volta em
  // manobra nova ou perto da parada — com manobra e km de rua reais)
  bool _hudVisible = false;
  Timer? _hudHideTimer;
  String _lastHudManeuverKey = '';

  // Voz do GPS (alto-falante da pilha lateral). Fala 1x de longe (300 m)
  // e 1x em cima (80 m) por manobra — sem repetir a cada fix.
  bool _voiceMuted = false;

  /// Paisagem: os controles do mapa ficam atrás de um botão só, porque a coluna
  /// vertical não cabe na altura deitada. Em retrato fica sempre falso.
  String _announcedFarKey = '';
  String _announcedNearKey = '';
  String _announcedArriveStopId = '';

  /// NÃO TRAVAR A ORIENTAÇÃO — app inteiro livre (retrato + paisagem).
  /// NÃO reintroduzir trava portrait-only aqui nem no main.dart.
  static const List<DeviceOrientation> _landscapeAllowed = [
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ];

  // NÃO TRAVAR A ORIENTAÇÃO — _portraitOnly removido de propósito.
  // Manter o app livre; não recriar essa lista.

  @override
  void initState() {
    super.initState();
    // NÃO TRAVAR A ORIENTAÇÃO — app livre; sem retorno a portrait no dispose.
    SystemChrome.setPreferredOrientations(_landscapeAllowed);
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
    // Bolhinha e alerta automático de atualização no boot: checa a versão publicada
    // no servidor e, se houver nova versão, abre a notificação/diálogo no app.
    unawaited(_checkUpdateOnBoot());
    // Card começa no piso (cabeçalho + botão inteiros, sem lista): o
    // usuário levanta se quiser. Só na 1ª montagem e sem toque anterior.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _sheetTouched) return;
      _sheetExtent = _sheetFloor();
      _sheetExtentNotifier.value = _sheetExtent;
    });
    // Expirado trava no PIX (confiança ou pagamento). Vale no boot e se
    // a assinatura vencer com o app aberto.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _maybeLockExpiredOnPix();
    });
    // Tutorial com holofote nas telas de verdade: 1x, com tudo assentado.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(milliseconds: 900), () {
        if (mounted) _startHomeCoach();
      });
    });
  }

  bool _graceLockOpened = false;

  /// Expirado + logado → renovação travada (sem voltar). O botão de
  /// confiança aparece dentro dela só para quem pode tomar.
  void _maybeLockExpiredOnPix() {
    if (_graceLockOpened || !mounted) return;
    final auth = ref.read(authControllerProvider);
    if (!auth.user.isLoggedIn) return;
    // Se o usuário ainda está em fase de ativação de trial (sem CPF ou pendente), NUNCA trava em checkout
    final cleanCpf = (auth.user.cpf ?? '').replaceAll(RegExp(r'\D'), '');
    final hasValidCpf = cleanCpf.length == 11 && CpfValidator.isValid(cleanCpf);
    if (!hasValidCpf || auth.user.plan.toLowerCase().contains('pendente')) return;
    if (auth.user.expiresAt.isAfter(DateTime.now())) return;
    _graceLockOpened = true;
    Future.delayed(const Duration(milliseconds: 600), () {
      if (mounted) SubscriptionRenewalScreen.openLocked(context);
    });
  }

  // ─── TUTORIAL (holofote nos widgets reais) ──────────────────────────────
  final GlobalKey _coachSearchKey = GlobalKey();
  final GlobalKey _coachScannerKey = GlobalKey();
  final GlobalKey _coachOptionsKey = GlobalKey();
  final GlobalKey _coachImportKey = GlobalKey();
  final GlobalKey _coachAddStopKey = GlobalKey();
  final GlobalKey _coachDrawerKey = GlobalKey();
  final GlobalKey _coachArrowKey = GlobalKey();
  final GlobalKey _coachSpeakerKey = GlobalKey();
  final GlobalKey _coachHudKey = GlobalKey();
  final GlobalKey _coachCardKey = GlobalKey();
  final GlobalKey _coachQrKey = GlobalKey();

  // ─── VALIDAÇÃO QR + GPS (PiP sob demanda) ─────────────────────────────
  // Toque no RASTREIO ou no botão da coluna abre uma janelinha de câmera.
  // Bipou → confere código + distância de 150 m. Nunca trava a entrega.
  bool _qrPipOpen = false;
  MobileScannerController? _qrPipController;
  bool _qrBusy = false;
  String _lastQrCode = '';
  DateTime? _lastQrAt;
  String? _verifiedStopId;
  _QrCheck _verifyResult = _QrCheck.none;
  double _verifyDistanceM = 0;
  int _verifiedOtherSeq = 0;
  DeliveryStop? _scannedStop;
  String? _scannedBarcode;

  Future<void> _startHomeCoach({bool force = false}) async {
    if (!mounted) return;
    // O tutorial SÓ deve rodar se o usuário estiver de fato na HOME:
    // sem modal/checkout por cima e com conta ativa.
    final isCurrent = ModalRoute.of(context)?.isCurrent ?? false;
    if (!isCurrent) return;

    final auth = ref.read(authControllerProvider);
    if (!auth.user.isLoggedIn) return;
    final cleanCpf = (auth.user.cpf ?? '').replaceAll(RegExp(r'\D'), '');
    final hasValidCpf = cleanCpf.length == 11 && CpfValidator.isValid(cleanCpf);
    if (!hasValidCpf || auth.user.plan.toLowerCase().contains('pendente')) return;
    if (!auth.user.expiresAt.isAfter(DateTime.now())) return;

    if (!force && await AppTutorial.isSeen(AppTutorial.homeSeenKey)) return;
    if (!mounted) return;
    // Estado vazio (1º login) tem outra tela: busca/scanner/⋯ nem existem.
    // Os passos se adaptam ao que está visível de verdade.
    final stops =
        ref.read(manifestControllerProvider).currentVersion?.stops ?? [];
    final steps = <CoachStep>[];
    if (stops.isEmpty) {
      steps.addAll([
        CoachStep(
          targetKey: _coachImportKey,
          title: 'Comece importando',
          body:
              'Toque em Importar manifesto: vale CSV, Excel, Shopee, Mercado Livre e Amazon. Com o GPS ligado, a parada 1 sai sempre a mais perto de você.',
        ),
        CoachStep(
          targetKey: _coachAddStopKey,
          title: 'Ou cadastre na mão',
          body:
              'Adicionar parada manual: digite o endereço que o app localiza no mapa e otimiza junto na rota.',
        ),
      ]);
    } else {
      steps.addAll([
        CoachStep(
          targetKey: _coachSearchKey,
          title: 'Busque endereço ou etiqueta',
          body:
              'Digite um endereço para adicionar parada rapidinho — ou um código de barras para achar o pacote e a parada dele no ato.',
        ),
        CoachStep(
          targetKey: _coachScannerKey,
          title: 'Bipe a carga pela câmera',
          body:
              'Aponta para a etiqueta e o app marca o volume como carregado, mostrando a parada e a posição dele no baú.',
        ),
        CoachStep(
          targetKey: _coachOptionsKey,
          title: 'Aqui mora tudo: ⋯',
          body:
              'Importar Manifesto (CSV, Excel, Shopee, ML, Amazon), Carregar Veículo na ordem LIFO, Versões da Rota que nunca se perdem e Otimizar a partir do GPS.',
        ),
      ]);
    }
    steps.addAll([
      CoachStep(
        targetKey: _coachDrawerKey,
        title: 'Menu da conta',
        body:
            'Minha Conta, assinatura via PIX, sair da conta — e o “?” abre a ajuda e este tutorial de novo.',
      ),
      CoachStep(
        targetKey: _coachArrowKey,
        title: 'Seta azul = câmera grudada',
        body:
            'Com ela azul, a câmera anda nas costas do cursor. Arrastou o mapa? Ela volta sozinha em segundos.',
      ),
    ]);
    // Replay (botão da Ajuda) fura a flag "já visto"; 1º login usa showOnce.
    if (force) {
      await CoachTutorial.show(context, steps);
    } else {
      await AppTutorial.showOnce(context, AppTutorial.homeSeenKey, steps);
    }
  }

  Future<void> _startNavCoach() async {
    if (!mounted) return;
    if (await AppTutorial.isSeen(AppTutorial.navSeenKey)) return;
    // Garante o HUD visível para apontar o holofote nele.
    _showManeuverHud(resetTimer: false);
    await Future.delayed(const Duration(milliseconds: 1200), () {});
    if (!mounted) return;
    await AppTutorial.showOnce(context, AppTutorial.navSeenKey, [
      CoachStep(
        targetKey: _coachHudKey,
        title: 'O HUD canta a curva',
        body:
            'Aqui aparece a próxima manobra com a distância real de rua. Ele some sozinho e volta em manobra nova.',
      ),
      CoachStep(
        targetKey: _coachSpeakerKey,
        title: 'Voz do GPS',
        body:
            'Azul = falando as curvas. Cortado = mudo. A voz avisa de longe e em cima de cada manobra.',
      ),
      CoachStep(
        targetKey: _coachCardKey,
        title: 'Card arrastável',
        body:
            'Arraste o card para o lado para trocar de parada. Concluir aqui avança sozinho para a próxima.',
      ),
      CoachStep(
        targetKey: _coachQrKey,
        title: 'Bipar no ponto',
        body:
            'Toque no rastreio ou aqui na câmera para bipar a etiqueta. O app confere o código e a distância de 150 m. Fora do ponto, a entrega segue liberada.',
      ),
    ]);
    if (mounted) _showManeuverHud();
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
  /// Com a seta ARMADA (azul), a câmera solta por alguns segundos p/ olhar
  /// livre e volta sozinha p/ trás do cursor — a seta continua azul.
  /// Com a seta desligada, a câmera fica livre até tocar na seta.
  void _onMapUserInteracted() {
    if (!_isNavigating) return;

    // Cancela qualquer retorno pendente (novo gesto = nova contagem)
    _autoRecenteringTimer?.cancel();
    _autoRecenteringTimer = null;

    // Solta a câmera agora (transitório — NÃO desarma a seta)
    if (_followGps || _courseUp) {
      setState(() {
        _followGps = false;
        _courseUp = false;
      });
    }

    // Armada: agenda a volta sozinha p/ trás do cursor.
    if (_autoRecenterArmed) {
      _autoRecenteringTimer = Timer(_kAutoRecenterDelay, () {
        if (!mounted || !_autoRecenterArmed || !_isNavigating) return;
        if (_currentLocation == null) return;
        setState(() {
          _followGps = true;
          _courseUp = true;
        });
        _flyBehindCursor(durationMs: 800);
      });
    }
  }

  /// Garante que a rota seja automaticamente re-otimizada a partir da localização do entregador.
  /// Offline pula (reotimizar sem OSRM não muda a ordem e ainda aposentaria
  /// a versão com a rua salva, apagando a linha do mapa).
  void _checkAndAutoReoptimize(LatLng latLng) {
    if (_didAutoReoptimize) return;
    if (!ConnectivityService.instance.isOnline.value) return;
    final manifestState = ref.read(manifestControllerProvider);
    // Já otimizada com GPS antes? Não cria "Otimizada N+1" à toa — era
    // isso que empilhava Otimizada 2..8 sozinho a cada boot.
    if (manifestState.hasGpsStart) {
      _didAutoReoptimize = true;
      return;
    }
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
        _publishGpsFix(lastLatLng);
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
      _publishGpsFix(latLng, speedKmh: pos.speed * 3.6, heading: pos.heading);
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
        // Sem setState: pin/HUD/velocidade ouvem os notifiers (Fase 1a).
        _publishGpsFix(next, speedKmh: p.speed * 3.6, heading: p.heading);
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
            // HUD temporário + voz da manobra (limiares, sem repetir)
            _updateManeuverHud(next, target);
            _maybeAnnounceManeuver(target);
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
    _livePin.dispose();
    _liveHeading.dispose();
    _gpsTick.dispose();
    _qrPipController?.dispose();
    // NÃO TRAVAR A ORIENTAÇÃO — mantém livre ao sair da tela; não voltar a portraitOnly.
    SystemChrome.setPreferredOrientations(_landscapeAllowed);
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

  /// Seta de recentralizar automático: liga = azul P/ SEMPRE (até tocar de
  /// novo). Ligar engata a câmera atrás do cursor na hora; mexer no mapa
  /// solta por alguns segundos e ela volta sozinha.
  void _toggleCourseUp() {
    _setAutoRecenterArmed(!_autoRecenterArmed);
  }

  void _setAutoRecenterArmed(bool armed) {
    if (!mounted) return;
    _autoRecenteringTimer?.cancel();
    _autoRecenteringTimer = null;
    if (!armed) {
      setState(() {
        _autoRecenterArmed = false;
        _followGps = false;
        _courseUp = false;
      });
      _animatedMapMove(_mapController.camera.center, _mapController.camera.zoom, destRotation: 0, durationMs: 500);
      return;
    }
    setState(() {
      _autoRecenterArmed = true;
      _followGps = true;
      _courseUp = true;
    });
    _flyBehindCursor(durationMs: 650);
  }

  /// Voa a câmera p/ trás do cursor (posição + zoom + rotação do modo atual).
  void _flyBehindCursor({int durationMs = 650}) {
    if (!mounted || _currentLocation == null) return;
    final course = _getForwardCourse();
    final targetRotation = (360.0 - course) % 360.0;
    if (_isNavigating) {
      final camCenter = _getNavigationCameraCenter(_currentLocation!, course);
      _animatedMapMove(camCenter, 17.2, destRotation: targetRotation, durationMs: durationMs);
    } else if (_courseUp) {
      _animatedMapMove(_currentLocation!, 16.5, destRotation: targetRotation, durationMs: durationMs);
    } else {
      _animatedMapMove(_currentLocation!, _mapController.camera.zoom, durationMs: durationMs);
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

  /// Abre/fecha a janelinha de câmera (PiP sob demanda). Fecha sozinha
  /// após bipar — o resultado fica registrado no card.
  void _toggleQrPip({bool? open}) {
    final next = open ?? !_qrPipOpen;
    if (next == _qrPipOpen) return;
    if (next) {
      _qrPipController?.dispose();
      _qrPipController = MobileScannerController(
        detectionSpeed: DetectionSpeed.normal,
        facing: CameraFacing.back,
        torchEnabled: false,
      );
      _qrBusy = false;
      _lastQrCode = '';
      _lastQrAt = null;
    } else {
      _qrPipController?.dispose();
      _qrPipController = null;
      _qrBusy = false;
    }
    if (mounted) setState(() => _qrPipOpen = next);
  }

  void _onQrPipDetect(BarcodeCapture capture) {
    if (!_qrPipOpen || _qrBusy) return;
    final barcodes = capture.barcodes;
    if (barcodes.isEmpty) return;
    final raw = barcodes.first.rawValue;
    if (raw == null || raw.trim().isEmpty) return;
    final code = raw.trim();
    final now = DateTime.now();
    if (code == _lastQrCode &&
        _lastQrAt != null &&
        now.difference(_lastQrAt!).inMilliseconds < 1200) {
      return;
    }
    _lastQrCode = code;
    _lastQrAt = now;
    _qrBusy = true;
    _runQrCheck(code);
  }

  /// Confere o código bipado contra a parada atual + distância do GPS.
  /// Nunca bloqueia: só registra o status exibido no card.
  Future<void> _runQrCheck(String code) async {
    final stops =
        ref.read(manifestControllerProvider).currentVersion?.stops ?? [];
    if (stops.isEmpty || !mounted) {
      _qrBusy = false;
      return;
    }
    final curIdx = _selectedStopIndex.clamp(0, stops.length - 1);
    final current = stops[curIdx];
    final norm = code.trim().toUpperCase();
    final ownCodes = current.packages
        .map((p) => p.barcode.trim().toUpperCase())
        .where((b) => b.isNotEmpty)
        .toSet();

    _QrCheck result;
    double dist = 0;
    int otherSeq = 0;
    DeliveryStop? ownerStop;

    if (ownCodes.contains(norm)) {
      final gps = _currentLocation ?? _livePin.value;
      if (gps == null) {
        result = _QrCheck.noGps;
      } else {
        dist = LifoCalculator.calculateDistanceMeters(
          gps.latitude,
          gps.longitude,
          current.latitude,
          current.longitude,
        );
        result = dist <= LifoCalculator.locationGateMeters
            ? _QrCheck.ok
            : _QrCheck.far;
      }
    } else {
      ownerStop = await ref
          .read(manifestControllerProvider.notifier)
          .findStopForBarcode(norm);
      if (!mounted) {
        _qrBusy = false;
        return;
      }
      if (ownerStop != null) {
        otherSeq = ownerStop.sequenceIndex;
        final gps = _currentLocation ?? _livePin.value;
        if (gps != null) {
          dist = LifoCalculator.calculateDistanceMeters(
            gps.latitude,
            gps.longitude,
            ownerStop.latitude,
            ownerStop.longitude,
          );
        }
        result = _QrCheck.other;
      } else {
        result = _QrCheck.unknown;
      }
    }

    HapticFeedback.mediumImpact();
    if (!mounted) {
      _qrBusy = false;
      return;
    }
    setState(() {
      _verifiedStopId = ownerStop?.id ?? current.id;
      _verifyResult = result;
      _verifyDistanceM = dist;
      _verifiedOtherSeq = otherSeq;
      _scannedStop = ownerStop;
      _scannedBarcode = norm;
      
      // Se encontrou a parada (mesmo que seja outra), "chama" o card dela
      if (ownerStop != null) {
        final idx = stops.indexWhere((s) => s.id == ownerStop!.id);
        if (idx != -1) {
          _selectedStopIndex = idx;
        }
      }
    });
    // Sob demanda: fecha a janelinha após bipar, status permanece no card.
    _toggleQrPip(open: false);
    _qrBusy = false;
  }

  void _openVehicleBayModal() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const VehicleBayScreen(),
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
                  icon: Icons.map_outlined,
                  label: 'Mapas offline',
                  subtitle: 'Baixa a cidade para usar sem internet',
                  textColor: textColor,
                  subColor: subColor,
                  onTap: () {
                    Navigator.pop(ctx);
                    OfflineMapsScreen.open(context);
                  },
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
    // Baseline do comparativo: trajeto ORIGINAL (rua + reta, ordem do arquivo).
    final baseline = await ImportManifestSheet.show(
      context,
      startLat: _currentLocation?.latitude,
      startLng: _currentLocation?.longitude,
    );
    if (baseline != null && mounted) {
      _fitToCurrentManifest();
      // F4 silencioso: com internet, baixa o entorno da rota em background
      // (cidade atual + pedacinho da vizinha). Sem rede, só pula.
      // ignore: unawaited_futures
      _ensureOfflineCoverage();

      // ── Pede o nome da rota ─────────────────────────────────────────────
      // Respiro p/ a sheet terminar de sair antes do dialog entrar (sem corte).
      await Future.delayed(const Duration(milliseconds: 300));
      if (!mounted) return;
      final isDark = Theme.of(context).brightness == Brightness.dark;
      final routeName = await showGeneralDialog<String>(
        context: context,
        barrierDismissible: false,
        barrierLabel: 'Dar nome à rota',
        barrierColor: Colors.black54,
        transitionDuration: const Duration(milliseconds: 340),
        transitionBuilder: (dialogCtx, animation, secondaryAnim, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
          );
          return FadeTransition(
            opacity: curved,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.9, end: 1.0).animate(curved),
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.08),
                  end: Offset.zero,
                ).animate(curved),
                child: child,
              ),
            ),
          );
        },
        pageBuilder: (ctx, anim, secondaryAnim) =>
            _RouteNameDialog(isDark: isDark),
      );

      if (routeName != null && mounted) {
        await ref.read(manifestControllerProvider.notifier).renameCurrentManifest(routeName);
      }

      // ── Sucesso ─────────────────────────────────────────────────────────
      if (!mounted) return;
      final s = ref.read(manifestControllerProvider);
      final v = s.currentVersion;
      if (v != null && mounted) {
        // Comparativo honesto: rua x rua quando há rede nos dois lados.
        // Offline (qualquer lado sem geometria de rua): zera e o dialog
        // mostra "—" / "sem estimativa" — nunca número de linha reta.
        double cmpOriginal;
        double cmpOptimized;
        if (baseline.originalRoad > 0 && s.totalDistanceMeters > 0) {
          cmpOriginal = baseline.originalRoad;
          cmpOptimized = s.totalDistanceMeters;
        } else {
          cmpOriginal = 0;
          cmpOptimized = 0;
        }
        final viewOnMap = await ImportSuccessDialog.show(
          context,
          version: v,
          totalDurationSeconds: s.totalDurationSeconds,
          routeComputedAt: s.routeComputedAt,
          totalDistanceMeters: cmpOptimized,
          originalDistanceMeters: cmpOriginal,
        );
        // "Ver no mapa" reenquadra a rota com a animação de câmera.
        if (viewOnMap == true && mounted) {
          _fitToCurrentManifest();
        }
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

  /// F4: garante tiles offline do bbox da rota + 2km, em background.
  /// Só com internet e sem download concorrente; falha silenciosa.
  Future<void> _ensureOfflineCoverage() async {
    try {
      if (!ConnectivityService.instance.isOnline.value) return;
      final stops =
          ref.read(manifestControllerProvider).currentVersion?.stops ?? [];
      if (stops.isEmpty) return;
      final points = [
        for (final s in stops) LatLng(s.latitude, s.longitude),
      ];
      // Roda sem await na chamada; aqui só executa e solta.
      unawaited(
        OfflineMapService.instance.ensureRouteCoverage(points),
      );
    } catch (_) {}
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
      _publishGpsFix(latLng, speedKmh: pos.speed * 3.6);
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
      if (mounted) _publishGpsFix(fix);
      return fix;
    } catch (_) {
      if (_currentLocation != null) return _currentLocation;
      try {
        final last = await Geolocator.getLastKnownPosition();
        if (last != null) {
          final fix = LatLng(last.latitude, last.longitude);
          if (mounted) _publishGpsFix(fix);
          return fix;
        }
      } catch (_) {}
      return null;
    }
  }

  Future<void> _reoptimizeWithGps() async {
    // Offline, otimizar não muda a ordem (sem OSRM) e o controller recusa
    // criar versão vazia para não aposentar a rua salva — avisa e mantém.
    if (!ConnectivityService.instance.isOnline.value &&
        await isOfflineFast()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Sem internet: mantendo a ordem atual e o traçado salvo.'),
        ),
      );
      return;
    }
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

  // ── Throttle do course (Fase 2a perf): a varredura completa da polyline
  // com haversine por ponto é cara p/ rodar a 1-3Hz. Reaproveita por até
  // 1,2s enquanto o veículo andar <25m (a câmera anima de todo jeito).
  int _lastCourseMs = 0;
  LatLng? _lastCoursePos;
  double _cachedCourse = 0.0;

  /// Obtém o azimute geográfico (0-360°) para onde a frente do veículo / rua à frente está apontando.
  double _getForwardCourse() {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final cur = _currentLocation;
    if (cur != null &&
        _lastCoursePos != null &&
        nowMs - _lastCourseMs < 1200) {
      final moved = LifoCalculator.calculateDistanceMeters(
        cur.latitude,
        cur.longitude,
        _lastCoursePos!.latitude,
        _lastCoursePos!.longitude,
      );
      if (moved < 25) return _cachedCourse;
    }
    final course = _computeForwardCourse();
    _lastCourseMs = nowMs;
    _lastCoursePos = cur;
    _cachedCourse = course;
    return course;
  }

  double _computeForwardCourse() {
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
        final steps = leg.steps;
        final cum = _cumulativeMeters(leg.points);
        final indices = _mapStepsToPolyline(leg.points, steps);
        setState(() {
          _legPolyline = leg.points;
          _legSteps = steps;
          _legCumMeters = cum;
          _legStepIndices = indices;
          _legClosestIdx = 0;
          _legRemainingMeters = cum.isNotEmpty ? cum.last : leg.distance;
          _lastHudManeuverKey = '';
          // NÃO zera os anunciados aqui: o refetch é periódico e a chave
          // leva o id da parada — troca de parada se vira sozinha.
        });
        _showManeuverHud();
      } else {
        // Sem traçado de rua: sem linha — nunca reta.
        setState(() {
          _legPolyline = [];
          _legSteps = [];
          _legStepIndices = [];
          _legCumMeters = [];
          _legClosestIdx = 0;
          _legRemainingMeters = -1;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _legPolyline = [];
          _legSteps = [];
          _legStepIndices = [];
          _legCumMeters = [];
          _legClosestIdx = 0;
          _legRemainingMeters = -1;
        });
      }
    }
  }

  /// Distância acumulada de rua (m) ponto a ponto da polyline.
  List<double> _cumulativeMeters(List<LatLng> points) {
    final cum = List<double>.filled(points.length, 0.0);
    for (int i = 1; i < points.length; i++) {
      cum[i] = cum[i - 1] +
          LifoCalculator.calculateDistanceMeters(
            points[i - 1].latitude,
            points[i - 1].longitude,
            points[i].latitude,
            points[i].longitude,
          );
    }
    return cum;
  }

  /// Índice na polyline onde cada manobra acontece (busca progressiva:
  /// manobras vêm na ordem da rota, então o cursor só anda p/ frente).
  List<int> _mapStepsToPolyline(List<LatLng> points, List<RouteStep> steps) {
    final indices = <int>[];
    int cursor = 0;
    for (final step in steps) {
      final loc = step.location;
      if (loc == null || points.isEmpty) {
        indices.add(-1);
        continue;
      }
      int best = cursor;
      double bestD = double.infinity;
      for (int i = cursor; i < points.length; i++) {
        final d = LifoCalculator.calculateDistanceMeters(
          loc.latitude,
          loc.longitude,
          points[i].latitude,
          points[i].longitude,
        );
        if (d < bestD) {
          bestD = d;
          best = i;
        }
      }
      cursor = best;
      indices.add(best);
    }
    return indices;
  }

  /// Ponto da polyline mais próximo do GPS (janela ao redor do último para
  /// ser barato a cada fix; varredura total se o GPS saltou >150 m).
  int _closestPolylineIndex(List<LatLng> points, LatLng pos, int hint) {
    if (points.isEmpty) return 0;
    double bestD = double.infinity;
    int best = hint.clamp(0, points.length - 1);
    final from = max(0, hint - 10);
    final to = min(points.length, hint + 60);
    for (int i = from; i < to; i++) {
      final d = LifoCalculator.calculateDistanceMeters(
        pos.latitude,
        pos.longitude,
        points[i].latitude,
        points[i].longitude,
      );
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    if (bestD > 150) {
      for (int i = 0; i < points.length; i++) {
        final d = LifoCalculator.calculateDistanceMeters(
          pos.latitude,
          pos.longitude,
          points[i].latitude,
          points[i].longitude,
        );
        if (d < bestD) {
          bestD = d;
          best = i;
        }
      }
    }
    return best;
  }

  /// Avança o progresso de rua a cada fix do GPS (chamado antes do rebuild,
  /// então o HUD lê valores frescos sem setState extra).
  void _refreshLegProgress(LatLng pos) {
    if (_legPolyline.length < 2 || _legCumMeters.length != _legPolyline.length) {
      return;
    }
    _legClosestIdx = _closestPolylineIndex(_legPolyline, pos, _legClosestIdx);
    final idx = _legClosestIdx.clamp(0, _legCumMeters.length - 1);
    _legRemainingMeters = max(0.0, _legCumMeters.last - _legCumMeters[idx]);
  }

  /// Próxima manobra à frente (>25 m): step + metros de rua até ela + índice.
  /// Null quando não há steps (offline) — o HUD usa o fallback de destino.
  ({RouteStep step, double metersTo, int index})? _currentManeuver() {
    if (_legSteps.isEmpty ||
        _legStepIndices.length != _legSteps.length ||
        _legCumMeters.isEmpty) {
      return null;
    }
    final cur = _legClosestIdx.clamp(0, _legCumMeters.length - 1);
    for (int i = 0; i < _legSteps.length; i++) {
      final si = _legStepIndices[i];
      if (si < 0) continue;
      final d = _legCumMeters[si.clamp(0, _legCumMeters.length - 1)] - _legCumMeters[cur];
      if (d > 25) return (step: _legSteps[i], metersTo: d, index: i);
    }
    // Tudo para trás: chegando — mostra o último step (normalmente arrive).
    final remaining = _legRemainingMeters < 0 ? 0.0 : _legRemainingMeters;
    return (
      step: _legSteps.last,
      metersTo: remaining,
      index: _legSteps.length - 1
    );
  }

  static String _formatRoadDistance(double meters) {
    if (meters < 0) return '';
    if (meters < 950) return '${meters.round()} m';
    return '${(meters / 1000.0).toStringAsFixed(1)} km';
  }

  /// Exibe o HUD por alguns segundos e some, como no Waze.
  /// HUD persistente durante a navegação: em vez de sumir após 6s, ele dá
  /// lugar ao nome da rua atual (pedido de uso em campo). Só apaga ao sair
  /// da navegação (ver [_resetNavigationState]).
  void _showManeuverHud({bool resetTimer = true}) {
    if (!mounted) return;
    _hudHideTimer?.cancel();
    if (!_hudVisible) {
      setState(() => _hudVisible = true);
    }
  }

  /// Liga/desliga a voz do GPS (alto-falante azul = falando).
  Future<void> _toggleVoiceMuted() async {
    final next = !_voiceMuted;
    setState(() => _voiceMuted = next);
    await VoiceGuidance.instance.setMuted(next);
  }

  /// Fala na hora em que a rota inicia (prova de voz + destino).
  /// Se o aparelho não tiver voz em português, avisa como instalar.
  Future<void> _speakRouteOpening(DeliveryStop stop) async {
    if (_voiceMuted) return;
    final destination =
        stop.recipientName.trim().isNotEmpty ? stop.recipientName.trim() : stop.address.trim();
    if (destination.isEmpty) return;
    final issue = await VoiceGuidance.instance.checkVoice();
    if (!mounted) return;
    if (issue != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Sem voz em português no aparelho: instale o app "Google TTS" e baixe a voz Português (Brasil). Tentando com a voz padrão…',
          ),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 6),
        ),
      );
    }
    await VoiceGuidance.instance.speak(
      VoiceGuidance.instance.openingInstruction(destination),
    );
  }

  /// Canta a manobra 1x de longe (300 m) e 1x em cima (80 m). Chave por
  /// manobra+rua p/ o refetch do trajeto (a cada 35 m) não repetir a frase.
  void _maybeAnnounceManeuver(DeliveryStop targetStop) {
    if (!_isNavigating || _voiceMuted) return;
    final m = _currentManeuver();
    if (m == null) return;
    if (m.step.maneuver == ManeuverType.arrive) {
      if (_legRemainingMeters >= 0 &&
          _legRemainingMeters < 60 &&
          _announcedArriveStopId != targetStop.id) {
        _announcedArriveStopId = targetStop.id;
        VoiceGuidance.instance.speak('Chegando ao destino');
      }
      return;
    }
    final key =
        '${targetStop.id}|${m.step.maneuver.name}|${m.step.streetName}';
    if (m.metersTo <= 300 && _announcedFarKey != key) {
      _announcedFarKey = key;
      VoiceGuidance.instance.speak(
        VoiceGuidance.instance.farInstruction(m.step, m.metersTo),
      );
    } else if (m.metersTo <= 80 && _announcedNearKey != key) {
      _announcedNearKey = key;
      VoiceGuidance.instance
          .speak(VoiceGuidance.instance.nearInstruction(m.step));
    }
  }

  /// Zera navegação + HUD + progresso de rua (sem rota não há o que guiar).
  void _resetNavigationState() {
    _hudHideTimer?.cancel();
    _autoRecenteringTimer?.cancel();
    _autoRecenteringTimer = null;
    VoiceGuidance.instance.stop();
    if (!mounted) return;
    setState(() {
      _isNavigating = false;
      _autoRecenterArmed = false;
      _courseUp = false;
      _selectedStopIndex = 0;
      _legPolyline = [];
      _lastLegTargetStopId = null;
      _legSteps = [];
      _legStepIndices = [];
      _legCumMeters = [];
      _legClosestIdx = 0;
      _legRemainingMeters = -1;
      _hudVisible = false;
      _lastHudManeuverKey = '';
      _announcedFarKey = '';
      _announcedNearKey = '';
      _announcedArriveStopId = '';
    });
  }

  /// Atualiza o progresso de rua e reexibe o HUD quando há manobra nova
  /// ou o carro está a <250 m da parada (fora isso ele some sozinho).
  void _updateManeuverHud(LatLng pos, DeliveryStop targetStop) {
    if (!_isNavigating) return;
    _refreshLegProgress(pos);
    final m = _currentManeuver();
    final key = m == null ? 'dest' : '${m.index}|${m.step.maneuver.name}';
    final nearStop =
        _legRemainingMeters >= 0 && _legRemainingMeters < 250;
    if (key != _lastHudManeuverKey || nearStop) {
      _lastHudManeuverKey = key;
      _showManeuverHud();
    }
  }


  void _startInAppNavigation(DeliveryStop stop, {bool forceFollow = false}) {
    _fetchRouteToTargetStop(stop);
    _showManeuverHud();
    // A voz abre junto com a rota (não espera a 1ª manobra chegar a 300 m).
    _speakRouteOpening(stop);
    // Tutorial da navegação (holofote): 1x na primeira rota.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _startNavCoach();
    });

    final alreadyNavigating = _isNavigating;

    setState(() {
      _isNavigating = true;
      // forceFollow = true: botão Navegar pressionado explicitamente → sempre
      //   ARMA o recentralizar (seta azul) e engata atrás do cursor.
      // forceFollow = false: mudança de parada via swipe → só arma na primeira
      //   vez que a navegação começa; se o usuário estava em free-look, mantém.
      if (forceFollow || !alreadyNavigating) {
        _autoRecenterArmed = true;
        _courseUp = true;
        _followGps = true;
      }
    });
    _autoRecenteringTimer?.cancel();
    _autoRecenteringTimer = null;

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

    // Assinatura venceu com o app aberto → trava no PIX.
    ref.listen(authControllerProvider, (prev, next) {
      final wasOk = (prev?.user.isLoggedIn ?? false) &&
          prev!.user.expiresAt.isAfter(DateTime.now());
      final isBad = next.user.isLoggedIn &&
          !next.user.expiresAt.isAfter(DateTime.now());
      if (wasOk && isBad && mounted) _maybeLockExpiredOnPix();
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
    // Piso do card acompanha o conteúdo: vazio precisa de mais altura
    // (2 botões) para nada cortar.
    _sheetFloorPx = stops.isEmpty ? _sheetEmptyPx : _sheetHeaderPx;

    final LatLng defaultCenter = stops.isNotEmpty
        ? LatLng(stops.first.latitude, stops.first.longitude)
        : (_currentLocation ?? const LatLng(-14.2350, -51.9253));

    final curIdx = (stops.isNotEmpty) 
        ? _selectedStopIndex.clamp(0, stops.length - 1) 
        : 0;
    final DeliveryStop? targetStop = (stops.isNotEmpty && curIdx < stops.length) 
        ? stops[curIdx] 
        : null;

    if (_isNavigating && stops.isEmpty) {
      // Proteção contra erro de renderização se o estado de navegação estiver ativo mas a lista vazia
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _isNavigating = false);
      });
    }

    // Se estiver navegando e mudou a parada alvo, busca traçado até ela
    if (_isNavigating && targetStop != null && _currentLocation != null && _lastLegTargetStopId != targetStop.id) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _fetchRouteToTargetStop(targetStop);
      });
    }

    // SEMPRE geometria de rua ou nada — nunca reta.
    // Navegando: perna GPS→parada quando há traçado de rua dela; senão a
    // rua salva inteira (o canvas realça o trecho até a parada ativa).
    // Offline sem rua salva: só marcadores + tiles até a rede voltar.
    final List<LatLng> effectivePolyline;
    if (_isNavigating && targetStop != null && _currentLocation != null) {
      effectivePolyline =
          (_legPolyline.isNotEmpty && _lastLegTargetStopId == targetStop.id)
              ? _legPolyline
              : manifestState.roadPolyline;
    } else {
      effectivePolyline = manifestState.roadPolyline;
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

    // Paisagem: painel fixo à esquerda (parada ou lista) e mapa à direita — Circuit.
    final media = MediaQuery.of(context);
    // Largura > altura: evita card de retrato embaixo do mapa quando o aparelho está deitado.
    final bool isLandscape = media.size.width > media.size.height;
    final bool splitPanel =
        MapSplitLayout.showsSidePanel(isLandscape: isLandscape);
    final double panelWidth =
        splitPanel ? MapSplitLayout.panelWidth(media.size.width) : 0.0;

    // Controles do mapa — os mesmos nas duas orientações: empilhados na vertical
    // em retrato, numa faixa horizontal em paisagem (que abre e fecha).
    final List<Widget> mapControlButtons = [
      if (_isNavigating)
        Container(
          key: _coachSpeakerKey,
          child: _buildFloatingCircleButton(
            context: context,
            icon: _voiceMuted
                ? Icons.volume_off_rounded
                : Icons.volume_up_rounded,
            tooltip: _voiceMuted
                ? 'Ativar voz do GPS'
                : 'Silenciar voz do GPS',
            isActive: !_voiceMuted,
            onTap: _toggleVoiceMuted,
          ),
        ),
      _buildFloatingCircleButton(
        context: context,
        icon: Icons.alt_route,
        tooltip: 'Re-otimizar Rota LIFO',
        onTap: _reoptimizeWithGps,
      ),
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
      _buildFloatingCircleButton(
        context: context,
        icon: Icons.my_location,
        tooltip: 'Minha Localização GPS',
        onTap: () => _onGpsButtonPressed(stops),
      ),
      if (_isNavigating)
        Container(
          key: _coachQrKey,
          child: _buildFloatingCircleButton(
            context: context,
            icon: _qrPipOpen
                ? Icons.qr_code_scanner_rounded
                : Icons.qr_code_2_rounded,
            tooltip: 'Bipar etiqueta do ponto',
            isActive: _qrPipOpen,
            onTap: () => _toggleQrPip(),
          ),
        ),
      Container(
        key: _coachArrowKey,
        child: _buildFloatingCircleButton(
          context: context,
          icon: Icons.navigation,
          tooltip: _autoRecenterArmed
              ? 'Recentralizar automático LIGADO (fica azul p/ sempre — toque p/ desligar)'
              : 'Recentralizar automático: câmera atrás do cursor',
          isActive: _autoRecenterArmed,
          onTap: _toggleCourseUp,
        ),
      ),
    ];

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      drawer: _buildCircuitDrawer(context, ref, currentVersion),
      body: SizedBox.expand(
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 1. ISOLATED LOGISTICS MAP CANVAS (em paisagem divide a tela com o
            // painel de paradas durante a visão geral; na navegação ocupa a tela cheia)
            Positioned.fill(
              left: (_isNavigating && stops.isNotEmpty) ? 0.0 : panelWidth,
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
                  livePin: _livePin,
                  liveHeading: _liveHeading,
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

            // 2. SELO OFFLINE (F5): mostra quando sem rede ou em sessão local.
            // Não bloqueia nada — scanner/baú/entrega seguem 100% locais.
            Positioned(
              top: 0,
              left: (_isNavigating && stops.isNotEmpty) ? 0.0 : panelWidth,
              right: 0,
              child: SafeArea(
                child: Center(
                  child: _OfflineBadge(
                    isOfflineAuth:
                        ref.watch(authControllerProvider).isOffline,
                  ),
                ),
              ),
            ),

            // 3. BOTÃO DE MENU (Posicionado de forma independente para estabilidade total)
            Positioned(
              top: 0,
              left: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.only(left: 16, top: 10),
                  child: Container(
                    key: _coachDrawerKey,
                    child: ValueListenableBuilder<AppRelease?>(
                      valueListenable: AppUpdateService.instance.availableUpdate,
                      builder: (context, release, _) =>
                          _buildFloatingCircleButton(
                        context: context,
                        icon: Icons.menu,
                        tooltip: release == null
                            ? 'Menu'
                            : 'Atualização disponível: ${release.version}',
                        badgeCount: release == null ? 0 : 1,
                        onTap: () => _scaffoldKey.currentState?.openDrawer(),
                      ),
                    ),
                  ),
                ),
              ),
            ),

            // 4. HUD DE MANOBRA (Centralização absoluta no topo sem interferência lateral)
            if (_isNavigating && targetStop != null)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: SafeArea(
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: media.size.width - (splitPanel ? panelWidth + 140 : 140),
                        ),
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
                              child: ValueListenableBuilder<int>(
                                valueListenable: _gpsTick,
                                builder: (context, _, _) =>
                                    _buildManeuverHud(targetStop: targetStop),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),

            // 5. CONTROLES DO MAPA (Lado direito, verticalmente empilhados)
            Positioned(
              top: 0,
              right: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.only(right: 16, top: 10),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (final botao in mapControlButtons) ...[
                        botao,
                        const SizedBox(height: 10),
                      ],
                      // Pílula de velocidade
                      ValueListenableBuilder<LatLng?>(
                        valueListenable: _livePin,
                        builder: (context, pin, _) => pin == null
                            ? const SizedBox.shrink()
                            : _buildSpeedPill(context),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // 6. SCANNER PIP (Lado direito, ao lado dos botões sem cobri-los)
            Positioned(
              top: 92,
              right: 74, // Offset para ficar à esquerda da coluna de botões (46px botão + padding)
              child: SafeArea(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  transitionBuilder: (Widget child, Animation<double> animation) {
                    return FadeTransition(
                      opacity: animation,
                      child: ScaleTransition(
                        scale: Tween<double>(begin: 0.8, end: 1.0).animate(
                          CurvedAnimation(parent: animation, curve: Curves.easeOutBack),
                        ),
                        child: child,
                      ),
                    );
                  },
                  child: _qrPipOpen
                      ? _buildQrPip(context)
                      : const SizedBox.shrink(),
                ),
              ),
            ),

            // 3. NAVEGAÇÃO ATIVA — Card flutuante e arrastável
            if (_isNavigating && stops.isNotEmpty && curIdx < stops.length)
              Positioned(
                key: const ValueKey('nav_card_container_stable'),
                left: isLandscape ? 16 : 14,
                right: isLandscape ? null : 14,
                width: isLandscape ? (media.size.width * 0.42).clamp(310.0, 360.0) : null,
                bottom: 12 + media.padding.bottom,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragStart: (_) => _cardDragAnimController.stop(),
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
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 400),
                        // NUNCA usar curva com overshoot aqui (easeOutBack & cia):
                        // o AnimatedSwitcher entrega ao transitionBuilder a
                        // animação JÁ curvada, e o t passa de 1.0. Quem consome
                        // (CurvedAnimation/FadeTransition/Opacity) exige t em
                        // [0,1] → assert + tela vermelha durante a troca de
                        // parada. O overshoot mora DENTRO do transitionBuilder,
                        // onde t ainda é <= 1.
                        switchInCurve: Curves.easeOut,
                        switchOutCurve: Curves.easeInCubic,
                        transitionBuilder: (child, animation) {
                          return FadeTransition(
                            opacity: animation,
                            child: ScaleTransition(
                              scale: Tween<double>(begin: 0.95, end: 1.0).animate(
                                CurvedAnimation(parent: animation, curve: Curves.easeOutBack),
                              ),
                              child: child,
                            ),
                          );
                        },
                        child: _buildActiveNavigationCard(
                          key: ValueKey('active_card_${targetStop?.id ?? "none"}'),
                          isDark: isDark,
                          isSidePanel: false,
                          stop: targetStop!, // Já garantido pelo 'if' do Positioned
                          currentIndex: curIdx,
                          totalStops: stops.length,
                          timeLabel: _stopTimeLabel(
                            index: curIdx,
                            stop: targetStop!,
                            arrivalOffsets: manifestState.arrivalOffsets,
                            routeComputedAt: manifestState.routeComputedAt,
                            isOnlineRouting: manifestState.isOnlineRouting,
                          ),
                          onMarkFailed: () {
                            if (stops.isEmpty || curIdx >= stops.length) return;
                            final isCurrentlyFailed = targetStop!.status == StopStatus.failed;
                            final newStatus = isCurrentlyFailed ? StopStatus.pending : StopStatus.failed;
                            ref.read(manifestControllerProvider.notifier).updateStopStatus(
                              targetStop.id,
                              newStatus,
                            );
                            if (!isCurrentlyFailed) {
                              _advanceToNextStop(stops);
                            }
                          },
                          onMarkCompleted: () {
                            if (stops.isEmpty || curIdx >= stops.length) return;
                            final isCurrentlyCompleted = targetStop!.status == StopStatus.completed;
                            final newStatus = isCurrentlyCompleted ? StopStatus.pending : StopStatus.completed;
                            ref.read(manifestControllerProvider.notifier).updateStopStatus(
                              targetStop.id,
                              newStatus,
                            );
                            if (!isCurrentlyCompleted) {
                              final allDone = stops.every((s) => s.id == targetStop.id || s.status == StopStatus.completed);
                              if (allDone) {
                                _autoRecenteringTimer?.cancel();
                                _autoRecenteringTimer = null;
                                _hudHideTimer?.cancel();
                                VoiceGuidance.instance.stop();
                                setState(() {
                                  _isNavigating = false;
                                  _autoRecenterArmed = false;
                                  _courseUp = false;
                                  _hudVisible = false;
                                  _cardDragDx = 0.0;
                                  _scannedStop = null;
                                  _scannedBarcode = null;
                                  _verifyResult = _QrCheck.none;
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
                                      : 'Parada #${targetStop.sequenceIndex} ENTREGUE! Avançando para a próxima...'),
                                  duration: const Duration(seconds: 2),
                                  backgroundColor: const Color(0xFF16A34A),
                                ),
                              );
                            }
                          },
                          onUndo: () {
                            if (stops.isEmpty || curIdx >= stops.length) return;
                            final curStop = targetStop!;
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
                            if (_scannedStop != null) {
                              setState(() {
                                _scannedStop = null;
                                _scannedBarcode = null;
                                _verifyResult = _QrCheck.none;
                              });
                              return;
                            }
                            _autoRecenteringTimer?.cancel();
                            _autoRecenteringTimer = null;
                            _hudHideTimer?.cancel();
                            VoiceGuidance.instance.stop();
                            setState(() {
                              _isNavigating = false;
                              _autoRecenterArmed = false;
                              _courseUp = false;
                              _hudVisible = false;
                              _cardDragDx = 0.0;
                              _scannedStop = null;
                              _scannedBarcode = null;
                              _verifyResult = _QrCheck.none;
                            });
                            _animatedMapMove(_mapController.camera.center, _mapController.camera.zoom, destRotation: 0, durationMs: 400);
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              )
            // Visão geral em paisagem: lista de paradas no painel esquerdo; retrato: bottom sheet.
            else if (splitPanel)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: panelWidth,
                child: RepaintBoundary(
                  child: _buildCircuitBottomSheet(
                    context: context,
                    isSidePanel: true,
                    currentVersion: currentVersion,
                    stops: stops,
                    isOnlineRouting: manifestState.isOnlineRouting,
                    totalDurationSeconds: manifestState.totalDurationSeconds,
                    totalDistanceMeters: manifestState.totalDistanceMeters,
                    hasRoadPolyline:
                        manifestState.roadPolyline.isNotEmpty,
                    arrivalOffsets: manifestState.arrivalOffsets,
                    routeComputedAt: manifestState.routeComputedAt,
                  ),
                ),
              )
            else if (!_isNavigating || stops.isEmpty)
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
                      totalDistanceMeters: manifestState.totalDistanceMeters,
                      hasRoadPolyline:
                          manifestState.roadPolyline.isNotEmpty,
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
    int badgeCount = 0,
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
    final button = Container(
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
    );
    return Tooltip(
      message: tooltip ?? '',
      child: badgeCount <= 0
          ? button
          : Stack(
              clipBehavior: Clip.none,
              children: [
                button,
                // Bolhinha com a contagem de atualizações pendentes.
                Positioned(
                  top: -3,
                  right: -3,
                  child: Container(
                    constraints: const BoxConstraints(minWidth: 18),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                    decoration: BoxDecoration(
                      color: AppColors.statusDanger,
                      borderRadius: BorderRadius.circular(9),
                      border: Border.all(color: bg.withValues(alpha: 0.95), width: 1.5),
                    ),
                    child: Text(
                      badgeCount > 9 ? '9+' : '$badgeCount',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        height: 1.3,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  /// Botão do drawer que substituiu o "Sair da conta" (o logout segue em
  /// Minha Conta & Configurações): mostra a versão publicada, e "Atualizar"
  /// quando o servidor tem uma mais nova que a instalada.
  Widget _buildUpdateButton(BuildContext context) {
    return ValueListenableBuilder<AppRelease?>(
      valueListenable: AppUpdateService.instance.availableUpdate,
      builder: (context, release, _) {
        final hasUpdate = release != null;
        return SizedBox(
          width: double.infinity,
          height: 38,
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(
              backgroundColor: hasUpdate
                  ? AppColors.circuitBlue
                  : AppColors.circuitBlue.withValues(alpha: 0.08),
              side: BorderSide(
                color: AppColors.circuitBlue.withValues(alpha: hasUpdate ? 1 : 0.45),
                width: 1.2,
              ),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              elevation: 0,
            ),
            onPressed: () => _checkForUpdates(),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  hasUpdate ? Icons.system_update_alt : Icons.refresh,
                  size: 17,
                  color: hasUpdate ? Colors.white : AppColors.circuitBlue,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    hasUpdate
                        ? 'Atualizar para ${release.version}'
                        : 'Verificar atualizações',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: hasUpdate ? Colors.white : AppColors.circuitBlue,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  bool _autoUpdatePrompted = false;

  /// Checagem automática no boot: se houver versão nova publicada, exibe a
  /// notificação/diálogo de atualização automaticamente ao abrir o app.
  Future<void> _checkUpdateOnBoot() async {
    final result = await AppUpdateService.instance.checkForUpdate();
    if (!mounted || _autoUpdatePrompted) return;
    if (result == UpdateCheck.available) {
      final release = AppUpdateService.instance.availableUpdate.value;
      if (release != null) {
        _autoUpdatePrompted = true;
        Future.delayed(const Duration(milliseconds: 800), () {
          if (mounted) {
            AppUpdateService.instance.showUpdateDialog(context, release);
          }
        });
      }
    }
  }

  /// Verificação disparada pelo botão: fala com o servidor (não usa só o
  /// cache) para não dizer "está atualizado" com informação velha.
  Future<void> _checkForUpdates() async {
    final messenger = ScaffoldMessenger.of(context);
    final update = AppUpdateService.instance;
    // O botão vive no drawer: fecha antes de abrir diálogo/snackbar.
    _scaffoldKey.currentState?.closeDrawer();
    final result = await update.checkNow();
    if (!mounted) return;
    final release = update.availableUpdate.value;
    void inform(String message) {
      messenger.showSnackBar(SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
      ));
    }

    switch (result) {
      case UpdateCheck.available:
        if (release != null) {
          await update.showUpdateDialog(context, release);
        }
      case UpdateCheck.upToDate:
        inform(
          'Você já está na versão publicada (${update.installedLabel.value}).',
        );
      case UpdateCheck.nothingPublished:
        // Servidor respondeu, mas o `release_apk.sql` ainda não rodou:
        // isso NÃO é falta de internet.
        inform('Nenhuma versão publicada no servidor ainda.');
      case UpdateCheck.offline:
        inform('Sem conexão para verificar atualizações.');
    }
  }

  /// Janelinha de câmera sob demanda, ao lado dos controles do mapa.
  /// Bipou → valida e fecha sozinha; o resultado fica no card.
  Widget _buildQrPip(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final border = isDark ? AppColors.carbonBorder : AppColors.lightBorder;
    final controller = _qrPipController;
    return Container(
      width: 148,
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: border, width: 1.2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 170,
            child: controller == null
                ? const Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : MobileScanner(
                    controller: controller,
                    onDetect: _onQrPipDetect,
                    errorBuilder: (context, error) {
                      return const Center(
                        child: Padding(
                          padding: EdgeInsets.all(12),
                          child: Text(
                            'Sem câmera',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          InkWell(
            onTap: () => _toggleQrPip(open: false),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 7),
              color: isDark
                  ? AppColors.carbonSurfaceInput
                  : AppColors.lightSurfaceElevated,
              child: Text(
                'Fechar',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: isDark
                      ? AppColors.textWhite
                      : AppColors.lightTextPrimary,
                ),
              ),
            ),
          ),
        ],
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
    /// Em paisagem o painel fica na lateral: cantos, sombra e alça mudam.
    bool isSidePanel = false,
    required dynamic currentVersion,
    required List<DeliveryStop> stops,
    required bool isOnlineRouting,
    required double totalDurationSeconds,
    required double totalDistanceMeters,
    required bool hasRoadPolyline,
    required List<double> arrivalOffsets,
    required DateTime? routeComputedAt,
  }) {
    final int totalStops = stops.length;
    final int loadedCount = currentVersion?.loadedPackagesCount ?? 0;
    final int totalCount = currentVersion?.totalPackagesInStops ?? 0;
    final double totalWeight = stops.fold(
      0.0,
      (acc, s) =>
          acc + s.packages.fold(0.0, (pAcc, p) => pAcc + (p.weightKg ?? 0)),
    );
    // Só mostra peso se o manifesto trouxe algum — nada de kg inventado.
    final bool hasKnownWeight =
        stops.any((s) => s.packages.any((p) => p.weightKg != null));
    final String weightSuffix =
        hasKnownWeight ? ' • ${totalWeight.toStringAsFixed(1)} kg' : '';

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final sheetBg = isDark ? AppColors.carbonSurface : AppColors.lightSurface;
    final sheetBorder = isDark ? AppColors.carbonBorder : AppColors.lightBorder;
    final inputBg = isDark ? AppColors.carbonSurfaceInput : AppColors.lightSurfaceInput;
    final inputBorder = isDark ? AppColors.carbonBorderSubtle : AppColors.lightBorderSubtle;
    final titleColor = isDark ? AppColors.textWhite : AppColors.lightTextPrimary;
    final subColor = isDark ? AppColors.textSlate : AppColors.lightTextSecondary;
    final mutedColor = isDark ? AppColors.textMuted : AppColors.lightTextMuted;

    // Painel lateral à esquerda (paisagem): cantos arredondados à direita.
    final BorderRadius sheetRadius = isSidePanel
        ? const BorderRadius.horizontal(right: Radius.circular(24))
        : const BorderRadius.vertical(top: Radius.circular(24));
    final Offset sheetShadowOffset =
        isSidePanel ? const Offset(6, 0) : const Offset(0, -6);

    if (currentVersion == null || stops.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          color: sheetBg,
          borderRadius: sheetRadius,
          border: Border.all(color: sheetBorder, width: 1.2),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.7 : 0.18),
              blurRadius: 20,
              offset: sheetShadowOffset,
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
              // No painel lateral a lista ocupa a altura toda: não há altura
              // para arrastar, então a alça some.
              if (!isSidePanel)
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
                key: _coachImportKey,
                onPressed: _openImport,
                icon: const Icon(Icons.upload_file_outlined, size: 18),
                label: const Text('Importar manifesto'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                key: _coachAddStopKey,
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
    final bool hasStoredRoad =
        totalDistanceMeters > 0 && hasRoadPolyline;
    final String etaLine = hasRealEta
        ? 'Chegada ≈ ${_hhmmFormat.format(routeComputedAt.add(Duration(seconds: totalDurationSeconds.round())))} • $totalStops paradas$weightSuffix'
        : hasStoredRoad
            ? '$totalStops paradas$weightSuffix • ${(totalDistanceMeters / 1000).toStringAsFixed(1)} km de rua'
            : '$totalStops paradas$weightSuffix • aguardando conexão';

    final nextIdx = _nextPendingIndex(stops);
    final isRouteInProgress = stops.any((s) => s.status == StopStatus.completed || s.status == StopStatus.inTransit);
    final allCompleted = stops.isNotEmpty && stops.every((s) => s.status == StopStatus.completed);

    final String buttonLabel = allCompleted
        ? 'Rota Concluída'
        : isRouteInProgress
            ? 'Continuar ${nextIdx + 1}/${stops.length}'
            : 'Iniciar Rota';

    // Ação única do botão de rota — usada tanto no layout de retrato (botão
    // grande de largura toda) quanto no compacto de paisagem (botão embutido
    // na linha de resumo).
    void startRoute() {
      if (allCompleted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content:
                Text('Todas as entregas deste manifesto já foram concluídas!'),
            backgroundColor: AppColors.circuitGreen,
          ),
        );
        return;
      }
      final idx = _nextPendingIndex(stops);
      setState(() => _selectedStopIndex = idx);
      _startInAppNavigation(stops[idx], forceFollow: true);
    }

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
        borderRadius: sheetRadius,
        border: Border.all(color: sheetBorder, width: 1.2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.7 : 0.18),
            blurRadius: 20,
            offset: sheetShadowOffset,
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (ctx, constraints) {
          // Altura natural máxima do cabeçalho (handle + busca + eta + título + botão + label).
          // Em paisagem o painel é estreito e comprido: com o cabeçalho
          // compacto (resumo + botão numa linha só) a lista de paradas ganha a
          // altura que antes ia embora. Com resultado de busca na tela o
          // cabeçalho precisa do espaço completo.
          final double headerNatH =
              isSidePanel ? (_packageSearchHit != null ? 232.0 : 140.0) : 232.0;
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
                  if (!isSidePanel)
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
            key: _coachSearchKey,
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
                  key: _coachScannerKey,
                  tooltip: 'Scanner de Carga',
                  icon: const Icon(Icons.qr_code_scanner, color: AppColors.circuitBlueGlow, size: 22),
                  onPressed: _openScanner,
                ),
                IconButton(
                  key: _coachOptionsKey,
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

          if (isSidePanel) ...[
            // Layout deitado: resumo e botão de rota na MESMA linha, para a
            // lista de paradas ficar com o resto da altura do painel.
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        currentVersion?.label.toUpperCase() ??
                            'MANIFESTO OPERACIONAL',
                        style: TextStyle(
                          color: titleColor,
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.2,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        etaLine,
                        style: TextStyle(
                          color: subColor,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppColors.circuitBlue.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '$loadedCount/$totalCount',
                    style: const TextStyle(
                      color: AppColors.circuitBlueGlow,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                if (stops.isNotEmpty && !_isNavigating) ...[
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: startRoute,
                    icon: const Icon(Icons.navigation_rounded, size: 16),
                    label: Text(
                      allCompleted ? 'Concluída' : 'Ir',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF2563EB),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      minimumSize: const Size(0, 38),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ] else ...[
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
                    currentVersion?.label.toUpperCase() ??
                        'MANIFESTO OPERACIONAL',
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
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
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
                  onPressed: startRoute,
                  icon: const Icon(Icons.navigation_rounded, size: 18),
                  label: Text(
                    buttonLabel,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
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
                      _animateSheetTo(_sheetFloor());
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

  /// Compartimentos distintos onde estão os volumes desta parada.
  List<SpatialSlot> _stopSlots(DeliveryStop stop) {
    final seen = <SpatialSlotType>{};
    final slots = <SpatialSlot>[];
    for (final pkg in stop.packages) {
      // Só conta local que o usuário realmente atribuiu no baú. O local
      // automático derivado do LIFO não significa que o volume foi colocado.
      if (!pkg.slotUserAssigned) continue;
      if (seen.add(pkg.spatialSlot.type)) slots.add(pkg.spatialSlot);
    }
    return slots;
  }

  /// Chip "LOCAL: Porta Traseira" — mostra onde achar os volumes no baú.
  /// Usa o nome personalizado do compartimento quando o motorista renomeou.
  Widget _buildStopLocationChip({
    required bool isDark,
    required DeliveryStop stop,
  }) {
    final slots = _stopSlots(stop);
    if (slots.isEmpty) return const SizedBox.shrink();
    final names = ref.read(slotNamesProvider);
    final labelColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Wrap(
        spacing: 5,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.grid_view_rounded, size: 13, color: labelColor),
              const SizedBox(width: 5),
              Text(
                'LOCAL: ',
                style: TextStyle(
                  fontSize: 9.5,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.4,
                  color: labelColor,
                ),
              ),
            ],
          ),
          for (final slot in slots)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: AppColors.primaryBlue,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                SlotNamesNotifier.labelOf(names, slot),
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
            ),
        ],
      ),
    );
  }

  // Fase 2b perf: construir DateFormat parseia o padrão (ICU) — 1x só.
  static final _hhmmFormat = DateFormat('HH:mm');

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
      return _hhmmFormat.format(eta);
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
                    _buildStopLocationChip(isDark: isDark, stop: stop),
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
                            color: isDark ? AppColors.carbonSurfaceInput : AppColors.lightSurfaceInput,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: isDark ? AppColors.carbonBorder : AppColors.lightBorder,
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

  /// Rua atual pelo progresso na perna (ver [LifoCalculator.streetAtProgress]).
  String? _currentStreetName() => LifoCalculator.streetAtProgress(
        _legSteps,
        _legStepIndices,
        _legClosestIdx,
      );

  /// HUD de navegação superior estilo Waze (na cor azul).
  /// Persistente durante a navegação: manobra próxima assume; fora disso
  /// mostra a rua atual em vez de sumir. Sem steps (offline), destino.
  Widget _buildManeuverHud({DeliveryStop? targetStop}) {
    if (targetStop == null) return const SizedBox.shrink();

    final maneuver = _currentManeuver();

    // Rua restante (dado de rua) ou "~" + distância GPS aproximada quando
    // não há traçado (offline sem rua salva). O "~" deixa claro que não é
    // medição de rua — nenhuma linha é desenhada a partir desse número.
    String distanceText = '';
    if (maneuver != null && _legRemainingMeters >= 0) {
      distanceText = _formatRoadDistance(_legRemainingMeters);
    } else if (_currentLocation != null) {
      final meters = LifoCalculator.calculateDistanceMeters(
        _currentLocation!.latitude,
        _currentLocation!.longitude,
        targetStop.latitude,
        targetStop.longitude,
      );
      distanceText = '~${_formatRoadDistance(meters)}';
    }

    // Linha principal e secundária do HUD.
    IconData icon = Icons.navigation_rounded;
    String mainLine = targetStop.recipientName;
    String? subLine =
        targetStop.address.isNotEmpty ? targetStop.address : null;
    final street = _currentStreetName();
    // Manobra próxima (≤300 m, mesmo limiar da voz de longe) assume o HUD;
    // fora disso o HUD mostra a rua atual em vez de sumir. Sem rua (offline
    // sem perna), cai no destino como antes.
    final nearManeuver = (maneuver != null &&
            (maneuver.metersTo <= 300 ||
                maneuver.step.maneuver == ManeuverType.arrive))
        ? maneuver
        : null;
    if (nearManeuver != null) {
      final step = nearManeuver.step;
      icon = step.icon;
      final arriving = step.maneuver == ManeuverType.arrive &&
          _legRemainingMeters >= 0 &&
          _legRemainingMeters < 60;
      if (arriving) {
        mainLine = 'Chegando ao destino';
        subLine = targetStop.address.isNotEmpty ? targetStop.address : null;
      } else {
        mainLine = step.label;
        final toManeuver = _formatRoadDistance(nearManeuver.metersTo);
        subLine = step.streetName.isNotEmpty
            ? '${step.streetName} • em $toManeuver'
            : 'em $toManeuver';
      }
    } else if (street != null && street.isNotEmpty) {
      // Modo rua: nome em destaque. Sem parada, sem km.
      icon = Icons.add_road;
      mainLine = street;
      subLine = null;
    }
    // Rua em destaque: rótulo pequeno em cima + nome grande.
    final streetMode =
        nearManeuver == null && street != null && street.isNotEmpty;

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
            child: Icon(
              icon,
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
                if (!streetMode)
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
                if (streetMode)
                  const Text(
                    'VOCÊ ESTÁ EM',
                    style: TextStyle(
                      color: Color(0xFFBFDBFE),
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                    ),
                  ),
                Text(
                  mainLine,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: streetMode ? 16.5 : 12.5,
                    fontWeight: FontWeight.w800,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (subLine != null && subLine.isNotEmpty) ...[
                  const SizedBox(height: 1),
                  Text(
                    subLine,
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

  /// Linha de status da validação QR + GPS. Sólida, curta, sem travar nada.
  Widget _buildVerifyLine({required bool isDark, required String stopId}) {
    if (_verifiedStopId != stopId || _verifyResult == _QrCheck.none) {
      return const SizedBox.shrink();
    }
    final Color dot;
    final String label;
    switch (_verifyResult) {
      case _QrCheck.ok:
        dot = AppColors.statusSuccess;
        label = 'Local confirmado';
        break;
      case _QrCheck.far:
      case _QrCheck.other:
        return const SizedBox.shrink();
      case _QrCheck.unknown:
        dot = AppColors.statusNeutral;
        label = 'Código fora do manifesto';
        break;
      case _QrCheck.noGps:
        dot = AppColors.statusNeutral;
        label = 'Código certo — sem GPS';
        break;
      case _QrCheck.none:
        return const SizedBox.shrink();
    }
    final textColor = isDark ? AppColors.textWhite : AppColors.lightTextPrimary;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: textColor,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNavigationCardDetails({
    required bool isDark,
    required bool isSidePanel,
    required DeliveryStop stop,
    required Color titleColor,
    required Color subColor,
    required Color cardBorder,
    required String? notes,
    VoidCallback? onTapTracking,
  }) {
    final barcodes = stop.packages
        .map((p) => p.barcode.trim())
        .where((b) => b.isNotEmpty)
        .toList();
    
    // Prioriza o código bipado no momento para exibição no card (mesmo que seja da parada atual)
    String trackingLabel;
    final isScannedCurrent = _scannedBarcode != null && _verifiedStopId == stop.id && (_verifyResult == _QrCheck.ok || _verifyResult == _QrCheck.far || _verifyResult == _QrCheck.noGps);
    final isScannedOther = _scannedBarcode != null && _verifiedStopId == stop.id && _verifyResult == _QrCheck.other;

    if (isScannedCurrent || isScannedOther) {
      trackingLabel = _scannedBarcode!;
    } else {
      trackingLabel = barcodes.isNotEmpty
          ? barcodes.join(' • ')
          : 'ID #${stop.sequenceIndex} (Sem código vinculado)';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          stop.recipientName,
          style: TextStyle(
            color: titleColor,
            fontSize: isSidePanel ? 17 : 15,
            fontWeight: FontWeight.w800,
          ),
          maxLines: isSidePanel ? 3 : 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 4),
        Text(
          stop.address,
          style: TextStyle(
            color: subColor,
            fontSize: isSidePanel ? 13 : 12,
            height: 1.35,
          ),
        ),
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTapTracking,
          child: Container(
          width: double.infinity,
          margin: const EdgeInsets.only(top: 10),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: cardBorder, width: 1),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
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
                  color: subColor,
                  letterSpacing: 0.6,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: Text(
                    trackingLabel,
                    key: ValueKey(trackingLabel),
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      fontFamily: 'monospace',
                      color: titleColor,
                      letterSpacing: 0.5,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
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
          ),
        ),
        _buildVerifyLine(isDark: isDark, stopId: stop.id),
        
        // Alerta de endereço divergente (bipagem fora de ordem ou longe)
        if ((_verifyResult == _QrCheck.other || _verifyResult == _QrCheck.far) && _verifiedStopId == stop.id) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.statusDanger.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.statusDanger.withValues(alpha: 0.3)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.warning_amber_rounded, color: AppColors.statusDanger, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _verifyResult == _QrCheck.other ? 'DIVERGÊNCIA DE LOCAL' : 'FORA DO PONTO',
                        style: const TextStyle(
                          color: AppColors.statusDanger,
                          fontSize: 11,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 2),
                      RichText(
                        text: TextSpan(
                          style: TextStyle(
                            color: isDark ? AppColors.textWhite : AppColors.lightTextPrimary,
                            fontSize: 12,
                            height: 1.4,
                          ),
                          children: [
                            const TextSpan(text: 'Você está em '),
                            TextSpan(
                              text: _currentStreetName() ?? 'local não identificado',
                              style: const TextStyle(fontWeight: FontWeight.w900, color: AppColors.circuitBlueGlow),
                            ),
                            const TextSpan(text: ' a '),
                            TextSpan(
                              text: _verifyDistanceM >= 1000 
                                  ? '${(_verifyDistanceM / 1000).toStringAsFixed(1)} km' 
                                  : '${_verifyDistanceM.round()} m',
                              style: const TextStyle(fontWeight: FontWeight.w900, color: AppColors.statusDanger),
                            ),
                            const TextSpan(text: ' do endereço correto.\n'),
                            TextSpan(
                              text: stop.address,
                              style: TextStyle(
                                fontSize: 11,
                                fontStyle: FontStyle.italic,
                                color: (isDark ? AppColors.textWhite : AppColors.lightTextPrimary).withValues(alpha: 0.7),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],

        _buildStopLocationChip(isDark: isDark, stop: stop),
        if (notes != null && notes.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: cardBorder),
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
        if (!isSidePanel) const SizedBox(height: 10),
      ],
    );
  }

  Widget _buildActiveNavigationCard({
    Key? key,
    required bool isDark,
    bool isSidePanel = false,
    required DeliveryStop stop,
    required int currentIndex,
    required int totalStops,
    required String timeLabel,
    required VoidCallback onMarkFailed,
    required VoidCallback onMarkCompleted,
    required VoidCallback onUndo,
    required VoidCallback onClose,
  }) {
    final theme = Theme.of(context);
    final titleColor = isDark ? AppColors.textWhite : AppColors.lightTextPrimary;
    final subColor = isDark ? AppColors.textSlate : AppColors.lightTextSecondary;
    final cardBg = isSidePanel
        ? theme.scaffoldBackgroundColor
        : (isDark ? AppColors.carbonSurface : AppColors.lightSurfaceElevated);
    final cardBorder = isDark ? AppColors.carbonBorder : AppColors.lightBorder;
    final notes = stop.notes?.trim();
    final isFinalized = stop.status == StopStatus.completed || stop.status == StopStatus.failed;
  
    return Container(
      key: key,
      width: isSidePanel ? double.infinity : null,
      height: isSidePanel ? double.infinity : null,
      padding: EdgeInsets.fromLTRB(
        isSidePanel ? 16 : 12,
        isSidePanel ? 12 : 10,
        isSidePanel ? 16 : 12,
        isSidePanel ? 16 : 10,
      ),
      decoration: isSidePanel
          ? BoxDecoration(
              color: cardBg,
              border: Border(
                right: BorderSide(
                  color: theme.dividerColor.withValues(alpha: 0.35),
                  width: 1,
                ),
              ),
            )
          : BoxDecoration(
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
        crossAxisAlignment:
            isSidePanel ? CrossAxisAlignment.stretch : CrossAxisAlignment.start,
        mainAxisSize: isSidePanel ? MainAxisSize.max : MainAxisSize.min,
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
              Flexible(
                child: Text(
                '${currentIndex + 1}/$totalStops, $timeLabel',
                style: TextStyle(
                  color: titleColor,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.2,
                ),
                overflow: TextOverflow.ellipsis,
              ),
              ),
              if (!isSidePanel) const SizedBox(width: 6),
              if (!isSidePanel)
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
        if (isSidePanel) ...[
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: Container(
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
          ),
        ],
        const SizedBox(height: 8),

        if (isSidePanel)
          Expanded(
            child: SingleChildScrollView(
              child: _buildNavigationCardDetails(
                isDark: isDark,
                isSidePanel: true,
                stop: stop,
                titleColor: titleColor,
                subColor: subColor,
                cardBorder: cardBorder,
                notes: notes,
                onTapTracking: () => _toggleQrPip(open: true),
              ),
            ),
          )
        else
          _buildNavigationCardDetails(
            isDark: isDark,
            isSidePanel: false,
            stop: stop,
            titleColor: titleColor,
            subColor: subColor,
            cardBorder: cardBorder,
            notes: notes,
            onTapTracking: () => _toggleQrPip(open: true),
          ),

          // As Ações do Card (Layout de 2 linhas limpo e sem truncamentos)
          const SizedBox(height: 10),
          if (isFinalized) ...[
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: _buildStopActionButton(
                    isDark: isDark,
                    isPrimary: true,
                    icon: const Icon(Icons.undo_rounded, size: 18, color: Colors.white),
                    label: 'Desfazer',
                    onTap: onUndo,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 3,
                  child: _buildStopStatusVisualizer(
                    isDark: isDark,
                    isCompleted: stop.status == StopStatus.completed,
                  ),
                ),
              ],
            ),
          ] else ...[
            Row(
              children: [
                Expanded(
                  child: _buildStopActionButton(
                    isDark: isDark,
                    isSelected: stop.status == StopStatus.failed,
                    disabled: false,
                    selectedColor: const Color(0xFFDC2626),
                    icon: _failedDeliveryIcon(isDark),
                    label: 'Não entregue',
                    onTap: onMarkFailed,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: _buildStopActionButton(
                    isDark: isDark,
                    isSelected: stop.status == StopStatus.completed,
                    disabled: false,
                    selectedColor: const Color(0xFF16A34A),
                    icon: _deliveredIcon(isDark),
                    label: 'Entregue',
                    onTap: onMarkCompleted,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _failedDeliveryIcon(bool isDark) {
    return SizedBox(
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
                child: Icon(Icons.close, size: 7, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _deliveredIcon(bool isDark) {
    return SizedBox(
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
                child: Icon(Icons.check, size: 7, color: Colors.white),
              ),
            ),
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
    bool disabled = false,
    Color? selectedColor,
    Color? customBg,
    Color? customBorder,
    Color? customTextColor,
  }) {
    final bg = customBg ??
        (disabled
            ? (isDark ? Colors.white.withValues(alpha: 0.05) : Colors.black.withValues(alpha: 0.05))
            : (isPrimary
                ? const Color(0xFF2563EB)
                : (isSelected
                    ? (selectedColor ?? const Color(0xFF2563EB))
                    : (isDark ? AppColors.carbonSurfaceInput : AppColors.lightSurfaceElevated))));
    final border = customBorder ??
        (disabled
            ? (isDark ? Colors.white.withValues(alpha: 0.1) : Colors.black.withValues(alpha: 0.1))
            : (isPrimary
                ? const Color(0xFF2563EB)
                : (isSelected
                    ? (selectedColor ?? const Color(0xFF2563EB))
                    : (isDark ? AppColors.carbonBorder : AppColors.lightBorder))));
    final textColor = customTextColor ??
        (disabled
            ? (isDark ? AppColors.textSlate.withValues(alpha: 0.5) : AppColors.lightTextSecondary.withValues(alpha: 0.5))
            : (isPrimary || isSelected
                ? Colors.white
                : (isDark ? AppColors.textWhite : AppColors.lightTextPrimary)));

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: disabled ? null : onTap,
        borderRadius: BorderRadius.circular(10),
        child: Opacity(
          opacity: disabled ? 0.6 : 1.0,
          child: Ink(
          height: 44,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: border, width: isSelected || isPrimary ? 1.2 : 1.0),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              icon,
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: textColor,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
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
            onPressed: () {
              Navigator.pop(dCtx);
              LegalDocumentScreen.open(ctx);
            },
            child: const Text('Termos & Privacidade', style: TextStyle(color: Color(0xFF2563EB), fontWeight: FontWeight.w700)),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(dCtx); // fecha o diálogo
              Navigator.of(ctx).pop(); // fecha o drawer p/ o holofote ver a tela
              await Future.delayed(const Duration(milliseconds: 350));
              if (mounted) _startHomeCoach(force: true);
            },
            child: const Text('Ver tutorial', style: TextStyle(color: Color(0xFF2563EB), fontWeight: FontWeight.w700)),
          ),
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
          _resetNavigationState();
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
          _resetNavigationState();
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
      // top:false para o gradiente do hero encostar no topo da tela
      // (atrás da status bar); o respiro vem de padding manual abaixo.
      child: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── TOP PROFILE / ACCOUNT HERO (gradiente até o topo) ───────
            Container(
              padding: EdgeInsets.fromLTRB(
                16,
                MediaQuery.of(context).padding.top + 10,
                16,
                16,
              ),
              clipBehavior: Clip.hardEdge,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: isDark
                      ? const [
                          Color(0xFF1E1B4B), // índigo profundo
                          Color(0xFF1D4ED8), // azul circuit
                          Color(0xFF0369A1), // ciano açoitado
                        ]
                      : const [
                          Color(0xFF1E40AF), // azul royal
                          Color(0xFF2563EB), // azul circuit
                          Color(0xFF38BDF8), // céu claro
                        ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: Stack(
                children: [
                  // Brilhos decorativos do gradiente.
                  Positioned(
                    right: -46,
                    top: -46,
                    child: Container(
                      width: 150,
                      height: 150,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withValues(alpha: 0.10),
                      ),
                    ),
                  ),
                  Positioned(
                    right: 44,
                    top: 22,
                    child: Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withValues(alpha: 0.10),
                      ),
                    ),
                  ),
                  Positioned(
                    left: -34,
                    bottom: -44,
                    child: Container(
                      width: 110,
                      height: 110,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.white.withValues(alpha: 0.07),
                      ),
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Ícones de ação no topo direito: Ajuda (?) e Configurações (⚙)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.help_outline,
                                size: 22, color: Colors.white70),
                            tooltip: 'Ajuda',
                            onPressed: () => _showHelpDialog(context),
                          ),
                          const SizedBox(width: 4),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.settings_outlined,
                                size: 22, color: Colors.white70),
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
                                  style: const TextStyle(
                                    color: Colors.white,
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
                                    color: Colors.white.withValues(alpha: 0.75),
                                    fontSize: 12,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  '${user.plan} • ${_formatCircuitExpiry(user.expiresAt)}',
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.85),
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

                  // Botão "⚡ Renovar" — vidro branco sobre o gradiente.
                  SizedBox(
                    width: double.infinity,
                    height: 38,
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        backgroundColor:
                            Colors.white.withValues(alpha: 0.16),
                        side: BorderSide(
                          color: Colors.white.withValues(alpha: 0.45),
                          width: 1.2,
                        ),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                        padding:
                            const EdgeInsets.symmetric(horizontal: 16),
                        elevation: 0,
                      ),
                      onPressed: () {
                        Navigator.pop(context); // Fecha o drawer antes de abrir a tela
                        SubscriptionRenewalScreen.open(context);
                      },
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.bolt, size: 18, color: Colors.white),
                          SizedBox(width: 6),
                          Text(
                            'Renovar',
                            style: TextStyle(
                              color: Colors.white,
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
                  ],
                  // O "Sair da conta" saiu daqui (o logout vive em Minha
                  // Conta & Configurações); o lugar é do update do APK.
                  const SizedBox(height: 4),
                  _buildUpdateButton(context),
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

/// Dialog "Dar nome à rota" com entrada em cascata (selo → título → campo
/// → botões) e teclado subindo DEPOIS da animação — sem o tranco de tudo
/// aparecer junto. Enter do teclado confirma.
class _RouteNameDialog extends StatefulWidget {
  final bool isDark;

  const _RouteNameDialog({required this.isDark});

  @override
  State<_RouteNameDialog> createState() => _RouteNameDialogState();
}

class _RouteNameDialogState extends State<_RouteNameDialog>
    with SingleTickerProviderStateMixin {
  late final AnimationController _enter;
  late final TextEditingController _nameCtrl;
  late final FocusNode _focus;

  late final Animation<double> _opSeal;
  late final Animation<double> _opTitle;
  late final Animation<double> _opField;
  late final Animation<Offset> _slideField;
  late final Animation<double> _opButtons;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController();
    _focus = FocusNode();
    _enter = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 750),
    );
    _opSeal = _fade(0.0, 0.30);
    _opTitle = _fade(0.12, 0.45);
    _opField = _fade(0.30, 0.65);
    _slideField = Tween<Offset>(
      begin: const Offset(0, 0.20),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(
        parent: _enter,
        curve: const Interval(0.30, 0.65, curve: Curves.easeOutCubic),
      ),
    );
    _opButtons = _fade(0.55, 0.90);
    _enter.forward();
    // Teclado só depois da entrada — dialog e teclado juntos é o tranco.
    Future.delayed(const Duration(milliseconds: 480), () {
      if (mounted) _focus.requestFocus();
    });
  }

  Animation<double> _fade(double begin, double end) =>
      Tween<double>(begin: 0, end: 1).animate(
        CurvedAnimation(
          parent: _enter,
          curve: Interval(begin, end, curve: Curves.easeOutCubic),
        ),
      );

  @override
  void dispose() {
    _enter.dispose();
    _nameCtrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _confirm() {
    final name = _nameCtrl.text.trim();
    Navigator.pop(context, name.isNotEmpty ? name : null);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final titleColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subColor =
        isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
    final borderColor =
        isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0);

    return AlertDialog(
      backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: FadeTransition(
        opacity: _opTitle,
        child: Row(
          children: [
            FadeTransition(
              opacity: _opSeal,
              child: Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: const Color(0xFF2563EB).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.drive_file_rename_outline_rounded,
                  color: Color(0xFF2563EB),
                  size: 21,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Dar nome à rota',
                style: TextStyle(
                  color: titleColor,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FadeTransition(
            opacity: _opTitle,
            child: Text(
              'Como você quer chamar esta rota?',
              style: TextStyle(color: subColor, fontSize: 13),
            ),
          ),
          const SizedBox(height: 12),
          FadeTransition(
            opacity: _opField,
            child: SlideTransition(
              position: _slideField,
              child: TextField(
                controller: _nameCtrl,
                focusNode: _focus,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _confirm(),
                style: TextStyle(color: titleColor, fontSize: 15),
                decoration: InputDecoration(
                  hintText: 'Ex: Rota Centro — Manhã',
                  hintStyle: TextStyle(color: subColor, fontSize: 14),
                  filled: true,
                  fillColor: isDark
                      ? const Color(0xFF0F172A)
                      : const Color(0xFFF8FAFC),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: borderColor),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: borderColor),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(
                      color: Color(0xFF2563EB),
                      width: 1.5,
                    ),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 13,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      actions: [
        FadeTransition(
          opacity: _opButtons,
          child: Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(
                    'Pular',
                    style: TextStyle(
                      color: subColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: ElevatedButton(
                  onPressed: _confirm,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2563EB),
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: const Text(
                    'Confirmar',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Selo "OFFLINE" (F5): aparece quando sem rede ou em sessão local.
/// Escuta [ConnectivityService.isOnline] + flag de sessão offline do auth.
class _OfflineBadge extends StatelessWidget {
  final bool isOfflineAuth;
  const _OfflineBadge({required this.isOfflineAuth});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: ConnectivityService.instance.isOnline,
      builder: (context, online, _) {
        // Se o celular está online (tem internet conectada), NÃO exibe o selo de offline.
        final show = !online;
        if (!show) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 56),
          child: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.72),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: Colors.orange.withValues(alpha: 0.6),
              ),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.cloud_off,
                  size: 13,
                  color: Colors.orange,
                ),
                SizedBox(width: 6),
                Text(
                  'OFFLINE • mapa e rotas locais',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
