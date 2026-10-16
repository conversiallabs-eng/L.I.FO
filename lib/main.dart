import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/theme/app_theme.dart';
import 'core/database/app_database.dart';
import 'core/map/tile_cache.dart';
import 'core/services/app_headers_service.dart';
import 'core/network/supabase_service.dart';
import 'core/network/connectivity_service.dart';
import 'core/services/map_config_service.dart';
import 'core/services/vector_style_service.dart';
import 'core/services/app_update_service.dart';
import 'core/utils/cpf_validator.dart';
import 'features/dashboard/presentation/screens/home_dashboard_screen.dart';
import 'features/auth/presentation/controllers/auth_controller.dart';
import 'features/auth/presentation/screens/login_screen.dart';
import 'features/auth/presentation/screens/complete_registration_screen.dart';

final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // NÃO TRAVAR A ORIENTAÇÃO — app livre (retrato + paisagem).
  // NÃO volte a restringir para portraitUp/portraitDown apenas: isso trava o app inteiro.
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  // Immersive UI — hide status bar on startup, re-shown by SystemChrome
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarBrightness: Brightness.dark,
    statusBarIconBrightness: Brightness.light,
  ));

  // Initialize SQLite immediately — fast, local-only, no network I/O
  await AppDatabase.instance.database;

  // Boot paralelo com timeouts curtos: sem internet o primeiro frame
  // não pode esperar rede (era isso que prendia no splash azul).
  // TileCache é só disco; Supabase falha rápido offline.
  // Headers de identificação do app (pacote + cert p/ trava CARTO).
  // Local e rápido (platform channel); nunca trava o boot.
  Map<String, String> appHeaders = const {};
  try {
    appHeaders = await AppHeadersService.instance
        .tileHeaders()
        .timeout(const Duration(seconds: 3));
  } catch (_) {}

  await Future.wait([
    TileCache.instance
        .initialize(extraHeaders: appHeaders)
        .timeout(const Duration(seconds: 3))
        .catchError((_) {}),
    SupabaseService.instance
        .initialize()
        .timeout(const Duration(seconds: 4))
        .catchError((_) {}),
  ]);

  // Atualiza chaves dinâmicas do mapa (Mapbox / Carto) do Supabase em background.
  // ignore: unawaited_futures
  MapConfigService.instance.refresh().catchError((e) {
    debugPrint('MapConfigService: erro ao atualizar chaves: $e');
  });

  // Pré-carrega o motor vetorial OpenFreeMap (Liberty & Dark) para o mapa abrir instantâneo.
  // ignore: unawaited_futures
  VectorStyleService.instance.preload();

  final container = ProviderContainer();
  // Observa a rede e drena a sync queue ao reconectar (F6).
  // O attach do stream é feito no dashboard (tem BuildContext); aqui só
  // tenta drenar o que já está pendente se o boot foi online.
  // ignore: unawaited_futures
  SupabaseService.instance.processSyncQueue().catchError((_) => 0);

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const LifoApp(),
    ),
  );
  // Liga o listener de reconexão no container raiz.
  ConnectivityService.instance.attach(container);
}

class LifoApp extends ConsumerStatefulWidget {
  const LifoApp({super.key});

  @override
  ConsumerState<LifoApp> createState() => _LifoAppState();
}

class _LifoAppState extends ConsumerState<LifoApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkAndPromptUpdate();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkAndPromptUpdate();
    }
  }

  Future<void> _checkAndPromptUpdate() async {
    try {
      final result = await AppUpdateService.instance.checkForUpdate();
      if (result == UpdateCheck.available) {
        final release = AppUpdateService.instance.availableUpdate.value;
        final navContext = rootNavigatorKey.currentContext;
        if (release != null && navContext != null && navContext.mounted) {
          AppUpdateService.instance.showUpdateDialog(navContext, release);
        }
      }
    } catch (e) {
      debugPrint('LifoApp: erro ao checar atualização: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authControllerProvider);

    Widget home;
    String switchKey;
    final user = authState.user;

    // Separação de telas: Ativação de Teste Grátis vs Checkout
    // Se o usuário está logado mas ainda não tem CPF válido auditado ou está com 'Pendente de Ativação',
    // ele vai estritamente para a tela de ativação de 30 dias grátis (CompleteRegistrationScreen).
    // NUNCA para a tela de checkout (PIX).
    final cleanCpf = (user.cpf ?? '').replaceAll(RegExp(r'\D'), '');
    final hasValidCpf = cleanCpf.length == 11 && CpfValidator.isValid(cleanCpf);
    final isPendingActivation = user.isLoggedIn &&
        (!hasValidCpf || user.plan.toLowerCase().contains('pendente'));

    if (authState.isBooting) {
      home = const _BootSplash();
      switchKey = 'boot';
    } else if (isPendingActivation) {
      home = const CompleteRegistrationScreen();
      switchKey = 'complete_registration';
    } else if (user.isLoggedIn) {
      home = const HomeDashboardScreen();
      switchKey = 'home';
    } else {
      home = const LoginScreen();
      switchKey = 'login';
    }

    return MaterialApp(
      navigatorKey: rootNavigatorKey,
      title: 'Lifo - Otimizador Logistico',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.system,
      // Troca login <-> home com fade + leve subida (manteiga, sem flash).
      home: AnimatedSwitcher(
        duration: const Duration(milliseconds: 380),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, animation) {
          final fade = FadeTransition(opacity: animation, child: child);
          final slide = SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.04),
              end: Offset.zero,
            ).animate(animation),
            child: fade,
          );
          return slide;
        },
        layoutBuilder: (current, previous) => Stack(
          alignment: Alignment.center,
          children: [...previous, ?current],
        ),
        child: KeyedSubtree(key: ValueKey(switchKey), child: home),
      ),
    );
  }
}

/// Splash exibido enquanto a sessão salva é restaurada (sem flash de login).
/// Respiração suave no logo p/ boot não parecer travado.
class _BootSplash extends StatelessWidget {
  const _BootSplash();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0066FF),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0.92, end: 1.0),
              duration: const Duration(milliseconds: 900),
              curve: Curves.easeOutCubic,
              builder: (context, scale, child) => Transform.scale(
                scale: scale,
                child: Opacity(
                  opacity: 0.4 + 0.6 * ((scale - 0.92) / 0.08).clamp(0.0, 1.0),
                  child: child,
                ),
              ),
              child: const Text(
                'L.I.F.O.',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 44,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 2,
                ),
              ),
            ),
            const SizedBox(height: 16),
            const CircularProgressIndicator(color: Colors.white),
          ],
        ),
      ),
    );
  }
}
