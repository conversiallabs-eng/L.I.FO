import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/theme/app_theme.dart';
import 'core/database/app_database.dart';
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

    return MaterialApp(
      title: 'Lifo - Otimizador Logistico',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: ThemeMode.system,
      home: authState.user.isLoggedIn
          ? const HomeDashboardScreen()
          : const LoginScreen(),
    );
  }
}
