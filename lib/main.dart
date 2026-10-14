import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/theme/app_theme.dart';
import 'core/database/app_database.dart';
import 'core/map/tile_cache.dart';
import 'core/network/supabase_service.dart';
import 'features/dashboard/presentation/screens/home_dashboard_screen.dart';
import 'features/auth/presentation/controllers/auth_controller.dart';
import 'features/auth/presentation/screens/login_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Lock orientation to portrait for in-vehicle use
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);

  // Immersive UI — hide status bar on startup, re-shown by SystemChrome
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarBrightness: Brightness.dark,
    statusBarIconBrightness: Brightness.light,
  ));

  // Initialize SQLite immediately — fast, local-only, no network I/O
  await AppDatabase.instance.database;

  // Cache de tiles do mapa em disco (Hive) — nunca trava o boot.
  await TileCache.instance.initialize();

  // Initialize Supabase before the app renders so Auth state is ready
  // on the very first frame (required for subscription check on startup)
  await SupabaseService.instance.initialize();

  runApp(
    const ProviderScope(
      child: LifoApp(),
    ),
  );
}

class LifoApp extends ConsumerWidget {
  const LifoApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authControllerProvider);

    Widget home;
    String switchKey;
    if (authState.isBooting) {
      home = const _BootSplash();
      switchKey = 'boot';
    } else if (authState.user.isLoggedIn) {
      home = const HomeDashboardScreen();
      switchKey = 'home';
    } else {
      home = const LoginScreen();
      switchKey = 'login';
    }

    return MaterialApp(
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
