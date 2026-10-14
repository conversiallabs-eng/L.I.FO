import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_cache/flutter_map_cache.dart';
import 'package:http_cache_hive_store/http_cache_hive_store.dart';
import 'package:path_provider/path_provider.dart';

/// Cache de tiles do mapa em disco (Hive).
///
/// Sem isso, cada movimento de câmera baixa os PNGs de novo via HTTP —
/// é o "pisca" dos tiles recarregando. Com o cache, áreas já visitadas
/// abrem instantâneas, inclusive offline.
///
/// Inicializado no boot em [initialize] (rápido, só local). Se falhar,
/// [provider] devolve um provedor só-em-memória e o mapa segue normal.
class TileCache {
  static final TileCache instance = TileCache._internal();
  TileCache._internal();

  CachedTileProvider? _provider;

  bool get isReady => _provider != null;

  /// NUNCA trava o boot: timeout curto + fallback silencioso.
  Future<void> initialize() async {
    if (_provider != null) return;
    try {
      final dir = await getTemporaryDirectory().timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw TimeoutException('path_provider lento'),
      );
      final store = HiveCacheStore('${dir.path}/lifo_map_tiles');
      _provider = CachedTileProvider(
        store: store,
        // Ruas mudam devagar: 30 dias sem revalidar é seguro e rápido.
        maxStale: const Duration(days: 30),
      );
      debugPrint('TileCache pronto em ${dir.path}/lifo_map_tiles');
    } catch (e) {
      debugPrint('TileCache indisponível (segue sem cache em disco): $e');
    }
  }

  /// Provedor com cache em disco, ou rede direta como fallback.
  TileProvider get provider => _provider ?? NetworkTileProvider();
}
