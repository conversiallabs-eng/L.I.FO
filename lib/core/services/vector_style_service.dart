import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';

/// Gerenciador de estilos vetoriais do OpenFreeMap (Liberty & Dark).
///
/// O OpenFreeMap é 100% gratuito, sem limite de requisições, sem chave de API
/// e sem risco de cobrança. O estilo Liberty entrega ruas nítidas, nomes em negrito
/// e alto contraste (acabando com o efeito de 'fumaça' e texto ilegível).
class VectorStyleService {
  static final VectorStyleService instance = VectorStyleService._internal();
  VectorStyleService._internal();

  static const String libertyStyleUrl =
      'https://tiles.openfreemap.org/styles/liberty';
  static const String darkStyleUrl =
      'https://tiles.openfreemap.org/styles/dark';

  Style? _cachedLightStyle;
  Style? _cachedDarkStyle;
  Future<Style>? _loadingLight;
  Future<Style>? _loadingDark;

  Style? cachedStyle({required bool isDark}) =>
      isDark ? _cachedDarkStyle : _cachedLightStyle;

  /// Pré-carrega os estilos vetoriais no boot do app em background
  Future<void> preload() async {
    try {
      await Future.wait([
        loadStyle(isDark: false),
        loadStyle(isDark: true),
      ]).timeout(const Duration(seconds: 8));
    } catch (e) {
      debugPrint('VectorStyleService: preload aviso: $e');
    }
  }

  /// Retorna o estilo vetorial correspondente (carregado ou em cache)
  Future<Style> loadStyle({required bool isDark}) {
    if (isDark) {
      if (_cachedDarkStyle != null) return Future.value(_cachedDarkStyle);
      _loadingDark ??= _fetchStyle(darkStyleUrl).then((style) {
        _cachedDarkStyle = style;
        return style;
      }).catchError((e) {
        _loadingDark = null;
        throw e;
      });
      return _loadingDark!;
    } else {
      if (_cachedLightStyle != null) return Future.value(_cachedLightStyle);
      _loadingLight ??= _fetchStyle(libertyStyleUrl).then((style) {
        _cachedLightStyle = style;
        return style;
      }).catchError((e) {
        _loadingLight = null;
        throw e;
      });
      return _loadingLight!;
    }
  }

  Future<Style> _fetchStyle(String url) async {
    debugPrint('VectorStyleService: buscando estilo $url...');
    final reader = StyleReader(uri: url);
    final style = await reader.read();
    debugPrint('VectorStyleService: estilo ${style.name} carregado com sucesso!');
    return style;
  }
}
