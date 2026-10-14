import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../presentation/screens/app_tutorial_screen.dart';

/// Tutorial de primeiro login: aparece UMA vez e nunca mais enche.
/// Versione a chave (_v1, _v2...) se um dia quiser reapresentar.
class AppTutorial {
  static const String _kSeenKey = 'lifo_tutorial_seen_v1';

  static Future<bool> isSeen() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_kSeenKey) ?? false;
    } catch (_) {
      return true;
    }
  }

  static Future<void> markSeen() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kSeenKey, true);
    } catch (_) {}
  }

  /// Mostra o tutorial se for a primeira vez. Marca como visto mesmo se
  /// a pessoa pular ou voltar — tutorial bom não persegue ninguém.
  static Future<void> maybeShow(BuildContext context) async {
    try {
      if (await isSeen()) return;
      if (!context.mounted) return;
      await AppTutorialScreen.open(context);
      await markSeen();
    } catch (_) {}
  }
}
