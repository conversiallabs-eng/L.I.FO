import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app_colors.dart';

class AppTheme {
  /// Transições suaves em todas as plataformas: deslize iOS (60/120fps,
  /// com driver nativo) no mobile + fade elegante no desktop/web.
  static const _pageTransitions = PageTransitionsTheme(
    builders: {
      TargetPlatform.android: CupertinoPageTransitionsBuilder(),
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder(),
      TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
      TargetPlatform.linux: FadeUpwardsPageTransitionsBuilder(),
    },
  );

  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      pageTransitionsTheme: _pageTransitions,
      splashFactory: InkSparkle.splashFactory,
      primaryColor: AppColors.circuitBlue,
      scaffoldBackgroundColor: AppColors.carbonBackground,
      colorScheme: const ColorScheme.dark(
        primary: AppColors.circuitBlue,
        secondary: AppColors.circuitCyan,
        surface: AppColors.carbonSurface,
        error: AppColors.circuitRed,
        onPrimary: Colors.white,
        onSecondary: Colors.black,
        onSurface: AppColors.textWhite,
        onError: Colors.white,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.carbonSurface,
        foregroundColor: AppColors.textWhite,
        elevation: 0,
        centerTitle: false,
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
          systemNavigationBarColor: AppColors.carbonSurface,
          systemNavigationBarIconBrightness: Brightness.light,
        ),
        titleTextStyle: TextStyle(
          color: AppColors.textWhite,
          fontSize: 18,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.2,
        ),
      ),
      cardTheme: CardThemeData(
        color: AppColors.carbonSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: AppColors.carbonBorder, width: 1),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.carbonBorderSubtle,
        thickness: 1,
        space: 1,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.circuitBlue,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          textStyle: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.textWhite,
          side: const BorderSide(color: AppColors.carbonBorder, width: 1.2),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          textStyle: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      textTheme: const TextTheme(
        displayLarge: TextStyle(color: AppColors.textWhite, fontSize: 30, fontWeight: FontWeight.w800, letterSpacing: -0.5),
        displayMedium: TextStyle(color: AppColors.textWhite, fontSize: 24, fontWeight: FontWeight.w700, letterSpacing: -0.4),
        titleLarge: TextStyle(color: AppColors.textWhite, fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: -0.2),
        titleMedium: TextStyle(color: AppColors.textWhite, fontSize: 15, fontWeight: FontWeight.w600),
        titleSmall: TextStyle(color: AppColors.textWhite, fontSize: 13, fontWeight: FontWeight.w600),
        bodyLarge: TextStyle(color: AppColors.textWhite, fontSize: 15, fontWeight: FontWeight.w400),
        bodyMedium: TextStyle(color: AppColors.textSlate, fontSize: 13, fontWeight: FontWeight.w400),
        bodySmall: TextStyle(color: AppColors.textMuted, fontSize: 11, fontWeight: FontWeight.w400),
        labelLarge: TextStyle(color: AppColors.textWhite, fontSize: 13, fontWeight: FontWeight.w700, letterSpacing: 0.2),
      ),
    );
  }

  // Light theme de verdade — alto contraste para sol na cabine.
  // Segue o tema do dispositivo via ThemeMode.system no MaterialApp.
  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      pageTransitionsTheme: _pageTransitions,
      splashFactory: InkSparkle.splashFactory,
      primaryColor: AppColors.circuitBlue,
      scaffoldBackgroundColor: AppColors.lightBackground,
      colorScheme: const ColorScheme.light(
        primary: AppColors.circuitBlue,
        secondary: AppColors.circuitCyan,
        surface: AppColors.lightSurface,
        error: AppColors.circuitRed,
        onPrimary: Colors.white,
        onSecondary: Colors.white,
        onSurface: AppColors.lightTextPrimary,
        onError: Colors.white,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.lightSurface,
        foregroundColor: AppColors.lightTextPrimary,
        elevation: 0,
        centerTitle: false,
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.dark,
          systemNavigationBarColor: AppColors.lightSurface,
          systemNavigationBarIconBrightness: Brightness.dark,
        ),
        titleTextStyle: TextStyle(
          color: AppColors.lightTextPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.2,
        ),
      ),
      cardTheme: CardThemeData(
        color: AppColors.lightSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: AppColors.lightBorder, width: 1),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.lightBorderSubtle,
        thickness: 1,
        space: 1,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.circuitBlue,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          textStyle: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.lightTextPrimary,
          side: const BorderSide(color: AppColors.lightBorder, width: 1.2),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          textStyle: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      textTheme: const TextTheme(
        displayLarge: TextStyle(color: AppColors.lightTextPrimary, fontSize: 30, fontWeight: FontWeight.w800, letterSpacing: -0.5),
        displayMedium: TextStyle(color: AppColors.lightTextPrimary, fontSize: 24, fontWeight: FontWeight.w700, letterSpacing: -0.4),
        titleLarge: TextStyle(color: AppColors.lightTextPrimary, fontSize: 18, fontWeight: FontWeight.w700, letterSpacing: -0.2),
        titleMedium: TextStyle(color: AppColors.lightTextPrimary, fontSize: 15, fontWeight: FontWeight.w600),
        titleSmall: TextStyle(color: AppColors.lightTextPrimary, fontSize: 13, fontWeight: FontWeight.w600),
        bodyLarge: TextStyle(color: AppColors.lightTextPrimary, fontSize: 15, fontWeight: FontWeight.w400),
        bodyMedium: TextStyle(color: AppColors.lightTextSecondary, fontSize: 13, fontWeight: FontWeight.w400),
        bodySmall: TextStyle(color: AppColors.lightTextMuted, fontSize: 11, fontWeight: FontWeight.w400),
        labelLarge: TextStyle(color: AppColors.lightTextPrimary, fontSize: 13, fontWeight: FontWeight.w700, letterSpacing: 0.2),
      ),
    );
  }
}
