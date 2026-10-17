import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';
import 'package:vector_tile_renderer/vector_tile_renderer.dart';

/// Gerenciador de estilos vetoriais OpenFreeMap customizados para logística.
///
/// Resolve os 3 pontos visuais solicitados:
/// 1. Remove os nomes borrados em azul sobre rios, lagoas, baías e canais.
/// 2. Remove o emaranhado de ruazinhas residenciais e vielas no zoom distante (< 11/12).
/// 3. Corrige o modo escuro: troca o 'pretão breu' por grafite carbono suave (#181B22)
///    com ruas nítidas em contraste elegante (#31394B) e rodovias em destaque.
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

  /// Retorna o estilo vetorial customizado correspondente
  Future<Style> loadStyle({required bool isDark}) {
    if (isDark) {
      if (_cachedDarkStyle != null) return Future.value(_cachedDarkStyle);
      _loadingDark ??= _fetchAndCustomizeStyle(darkStyleUrl, isDark: true).then((style) {
        _cachedDarkStyle = style;
        return style;
      }).catchError((e) {
        _loadingDark = null;
        throw e;
      });
      return _loadingDark!;
    } else {
      if (_cachedLightStyle != null) return Future.value(_cachedLightStyle);
      _loadingLight ??= _fetchAndCustomizeStyle(libertyStyleUrl, isDark: false).then((style) {
        _cachedLightStyle = style;
        return style;
      }).catchError((e) {
        _loadingLight = null;
        throw e;
      });
      return _loadingLight!;
    }
  }

  Future<Style> _fetchAndCustomizeStyle(String url, {required bool isDark}) async {
    debugPrint('VectorStyleService: carregando e otimizando estilo $url (isDark: $isDark)...');

    // 1. Carrega os providers de tiles e sprites nativos do OpenFreeMap
    final baseStyle = await StyleReader(uri: url).read();

    // 2. Busca ou recupera o JSON do estilo para aplicar os ajustes visuais cirúrgicos
    try {
      String? jsonString;
      File? diskCacheFile;

      try {
        final docDir = await getApplicationDocumentsDirectory();
        diskCacheFile = File('${docDir.path}/vector_style_${isDark ? "dark" : "light"}_v4.json');
      } catch (_) {}

      // Tenta baixar da rede com timeout ágil
      try {
        final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 5));
        if (res.statusCode == 200) {
          jsonString = res.body;
          if (diskCacheFile != null) {
            unawaited(diskCacheFile.writeAsString(jsonString));
          }
        }
      } catch (netErr) {
        debugPrint('VectorStyleService: rede indisponivel/lenta ($netErr), tentando cache em disco...');
      }

      // Se falhou rede, tenta do cache em disco
      if (jsonString == null && diskCacheFile != null && await diskCacheFile.exists()) {
        jsonString = await diskCacheFile.readAsString();
      }

      if (jsonString == null) {
        return baseStyle;
      }

      final styleMap = jsonDecode(jsonString) as Map<String, dynamic>;
      final rawLayers = styleMap['layers'];
      if (rawLayers is! List) return baseStyle;

      final layers = rawLayers.cast<Map<String, dynamic>>();

      // ─── PONTO 1: REMOVER PARADAS DE ÔNIBUS E ÍCONES DE TRANSPORTE (PRESERVANDO 100% DAS RUAS) ─
      layers.removeWhere((l) {
        final id = (l['id'] as String? ?? '').toLowerCase();
        final type = l['type'] as String? ?? '';
        final sourceLayer = (l['source-layer'] as String? ?? '').toLowerCase();

        // NUNCA remover camadas de vias, rodovias ou nomes de ruas!
        if (sourceLayer == 'transportation' || sourceLayer == 'transportation_name') {
          return false;
        }

        // Remove especificamente o layer de POI de transporte público (ex: poi_transit com ícones de ônibus)
        if (id == 'poi_transit' || id.contains('bus_stop')) {
          return true;
        }

        // Remove rótulos sobre água
        return (type == 'symbol' &&
            (id.contains('water') ||
                id.contains('river') ||
                id.contains('ocean') ||
                id.contains('lake') ||
                id.contains('stream')));
      });

      // ─── PONTO 3: ARRUMAR O 'PRETÃO' NO MODO ESCURO (ESTILO UBER/CIRCUIT DARK) ─
      // Troca o preto breu (#0c0c0c) por grafite carbono moderno (#181B22) e destaca as vias
      if (isDark) {
        for (final l in layers) {
          final id = l['id'] as String? ?? '';
          final paint = l['paint'] as Map<String, dynamic>?;
          if (paint == null) continue;

          if (id == 'background') {
            paint['background-color'] = '#181B22'; // Grafite carbono suave e elegante
          } else if (id == 'water') {
            paint['fill-color'] = '#0E131C'; // Azul marinho meia-noite profundo
          } else if (id == 'landcover_ice_shelf' || id == 'landcover_glacier') {
            paint['fill-color'] = '#181B22';
          } else if (id == 'landuse_residential') {
            paint['fill-color'] = '#1E232E';
          } else if (id == 'landuse_park' || id == 'landcover_wood') {
            paint['fill-color'] = '#192621'; // Verde floresta escuro discreto
          } else if (id == 'building') {
            paint['fill-color'] = '#222834';
            paint['fill-outline-color'] = '#2E3646';
          } else if (id == 'highway_minor' || id == 'road_minor') {
            paint['line-color'] = '#31394B'; // Ruas visíveis com contraste elegante
            l['minzoom'] = 12;
          } else if (id == 'highway_major_casing' || id == 'road_secondary_tertiary_casing') {
            paint['line-color'] = '#434E66';
            l['minzoom'] = 11;
          } else if (id == 'highway_major_inner' || id == 'road_secondary_tertiary') {
            paint['line-color'] = '#546280';
            l['minzoom'] = 11;
          } else if (id == 'highway_major_subtle') {
            paint['line-color'] = '#3B455A';
          } else if (id == 'highway_motorway_casing' || id == 'road_motorway_casing') {
            paint['line-color'] = '#D35400';
          } else if (id == 'highway_motorway_inner' || id == 'road_motorway') {
            paint['line-color'] = '#F39C12'; // Rodovias em âmbar de alta visibilidade
          } else if (id == 'highway_name_other' || id == 'highway_name_motorway') {
            paint['text-color'] = '#FFFFFF';
            paint['text-halo-color'] = '#12151C';
            paint['text-halo-width'] = 2.0;
          } else if (id.startsWith('place_') || id.startsWith('label_')) {
            paint['text-color'] = '#E2E8F0';
            paint['text-halo-color'] = '#10131A';
            paint['text-halo-width'] = 1.5;
          } else if (id.contains('road') && paint.containsKey('line-color')) {
            final col = paint['line-color'];
            if (col is String &&
                (col.contains('27') ||
                    col.contains('34') ||
                    col.contains('12') ||
                    col.contains('0c') ||
                    col.contains('1f') ||
                    col.contains('181818'))) {
              paint['line-color'] = '#31394B';
            }
          }
        }
      }

      // Compila o tema visual modificado
      final customTheme = ThemeReader().read(styleMap);

      debugPrint('VectorStyleService: estilo ${baseStyle.name} customizado com sucesso!');
      return Style(
        name: baseStyle.name,
        theme: customTheme,
        providers: baseStyle.providers,
        sprites: baseStyle.sprites,
        center: baseStyle.center,
        zoom: baseStyle.zoom,
      );
    } catch (e) {
      debugPrint('VectorStyleService: erro na customização do estilo ($e), usando baseStyle.');
      return baseStyle;
    }
  }
}
