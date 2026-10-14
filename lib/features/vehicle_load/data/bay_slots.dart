import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Quantidade de compartimentos ativos no baú.
///
/// Os 6 primeiros são as zonas LIFO (Fundo/Meio/Portas), que ficam fixas —
/// o usuário só adiciona/remove os extras, até o limite.
class BaySlotsNotifier extends StateNotifier<int> {
  static const String _kPrefsKey = 'lifo_bay_slot_count_v1';
  static const int minSlots = 6;
  static const int maxSlots = 12;
  static const int defaultSlots = 6;

  BaySlotsNotifier() : super(defaultSlots) {
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getInt(_kPrefsKey);
      if (saved != null) state = saved.clamp(minSlots, maxSlots);
    } catch (_) {}
  }

  Future<void> setCount(int value) async {
    final clamped = value.clamp(minSlots, maxSlots);
    if (clamped == state) return;
    state = clamped;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kPrefsKey, clamped);
    } catch (_) {}
  }
}

final baySlotCountProvider =
    StateNotifierProvider<BaySlotsNotifier, int>((ref) => BaySlotsNotifier());
