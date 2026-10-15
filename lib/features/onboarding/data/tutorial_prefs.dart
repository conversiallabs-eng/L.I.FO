import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../presentation/widgets/coach_tutorial.dart';

/// Tutorial com holofote nas telas de verdade: aparece UMA vez em cada
/// momento e nunca mais enche. Versione as chaves (_v1, _v2...) para reexibir.
class AppTutorial {
  static const String homeSeenKey = 'lifo_coach_home_seen_v1';
  // v2: card sem Navegar/Próxima (swipe) + validação QR 150 m.
  static const String navSeenKey = 'lifo_coach_nav_seen_v2';

  static Future<bool> isSeen(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(key) ?? false;
    } catch (_) {
      return true;
    }
  }

  static Future<void> markSeen(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(key, true);
    } catch (_) {}
  }

  /// Mostra 1x (marca como visto mesmo se pular — tutorial bom não persegue).
  static Future<void> showOnce(
    BuildContext context,
    String flag,
    List<CoachStep> steps,
  ) async {
    try {
      if (await isSeen(flag)) return;
      if (!context.mounted) return;
      await CoachTutorial.show(context, steps);
      await markSeen(flag);
    } catch (_) {}
  }
}
