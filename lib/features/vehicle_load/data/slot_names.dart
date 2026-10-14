import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../route_manifest/domain/models/spatial_slot.dart';

/// Nomes personalizados dos compartimentos do baú ("Corredor", "Geladeira"...).
/// Chave = SpatialSlotType.name. Vazio/ausente = rótulo padrão do slot.
class SlotNamesNotifier extends StateNotifier<Map<String, String>> {
  static const _kPrefsKey = 'lifo_slot_names_v1';

  SlotNamesNotifier() : super(const {}) {
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys().where((k) => k.startsWith('$_kPrefsKey.'));
      if (keys.isEmpty) return;
      final map = <String, String>{};
      for (final k in keys) {
        final type = k.substring(_kPrefsKey.length + 1);
        final name = prefs.getString(k)?.trim() ?? '';
        if (name.isNotEmpty) map[type] = name;
      }
      state = Map.unmodifiable(map);
    } catch (_) {}
  }

  Future<void> rename(SpatialSlotType type, String name) async {
    final clean = name.trim();
    final next = Map<String, String>.of(state);
    if (clean.isEmpty) {
      next.remove(type.name);
    } else {
      next[type.name] = clean;
    }
    state = Map.unmodifiable(next);
    try {
      final prefs = await SharedPreferences.getInstance();
      if (clean.isEmpty) {
        await prefs.remove('$_kPrefsKey.${type.name}');
      } else {
        await prefs.setString('$_kPrefsKey.${type.name}', clean);
      }
    } catch (_) {}
  }

  /// Rótulo de exibição: customizado ou padrão.
  static String labelOf(Map<String, String> names, SpatialSlot slot) {
    final custom = (names[slot.type.name] ?? '').trim();
    return custom.isEmpty ? slot.label : custom;
  }
}

final slotNamesProvider =
    StateNotifierProvider<SlotNamesNotifier, Map<String, String>>(
  (ref) => SlotNamesNotifier(),
);
