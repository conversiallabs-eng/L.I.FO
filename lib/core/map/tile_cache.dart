import 'dart:async';
import 'dart:io';
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
/// F2 (offline-first): o store mora em `getApplicationDocumentsDirectory`
/// (persistente — o SO não limpa), com fallback para o temporário.
/// O mesmo store é usado pelo pré-download de cidades
/// ([OfflineMapService]) via o Dio interno do [CachedTileProvider].
///
/// Inicializado no boot em [initialize] (rápido, só local). Se falhar,
/// [provider] devolve um provedor só-em-memória e o mapa segue normal.
class TileCache {
  static final TileCache instance = TileCache._internal();
  TileCache._internal();

  CachedTileProvider? _provider;
  String? _storePath;

  bool get isReady => _provider != null;

  /// Diretório persistente do Hive (para diagnóstico e tamanho em disco).
  String? get storePath => _storePath;

  /// Dio com interceptor de cache — usado pelo pré-download offline para
  /// popular o MESMO Hive que o TileLayer lê (não baixa em duplicidade).
  dynamic get dioForPrefetch {
    final p = _provider;
    if (p is! CachedTileProvider) return null;
    try {
      return p.dio;
    } catch (_) {
      return null;
    }
  }

  /// NUNCA trava o boot: timeout curto + fallback silencioso.
  /// [extraHeaders]: identificação do app (pacote + cert) p/ travas de
  /// provedor (ex.: mobile-app da CARTO). Vão no Dio do cache e no prefetch.
  Future<void> initialize({Map<String, String>? extraHeaders}) async {
    if (_provider != null) return;
    try {
      final dir = await _persistentDir().timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw TimeoutException('path_provider lento'),
      );
      final store = HiveCacheStore(
        '${dir.path}/lifo_map_tiles',
        hiveBoxName: 'lifo_map_tiles_v1',
      );
      _provider = CachedTileProvider(
        store: store,
        // NÃO usar const aqui: o flutter_map/Dio muta o map de headers
        // internamente e const estoura "Cannot modify unmodifiable map".
        headers: {
          'User-Agent': 'LifoApp/1.0 (com.lifo.app)',
          if (extraHeaders != null) ...extraHeaders,
        },
        // Ruas mudam devagar: 30 dias sem revalidar é seguro e rápido.
        maxStale: const Duration(days: 30),
      );
      _storePath = '${dir.path}/lifo_map_tiles';
      debugPrint('TileCache pronto em $_storePath');
    } catch (e) {
      debugPrint('TileCache indisponível (segue sem cache em disco): $e');
    }
  }

  /// Documentos (persistente) → temporário (fallback) → null.
  Future<Directory> _persistentDir() async {
    try {
      return await getApplicationDocumentsDirectory();
    } catch (_) {
      return await getTemporaryDirectory();
    }
  }

  /// Tamanho aproximado do cache em disco (para a tela Mapas Offline).
  /// Retorna -1 se indisponível.
  Future<int> cacheSizeBytes() async {
    try {
      final path = _storePath;
      if (path == null) return -1;
      final dir = Directory(path);
      if (!await dir.exists()) return 0;
      int total = 0;
      await for (final f in dir.list(recursive: true, followLinks: false)) {
        if (f is File) {
          try {
            total += await f.length();
          } catch (_) {}
        }
      }
      return total;
    } catch (_) {
      return -1;
    }
  }

  /// Provedor com cache em disco, ou rede direta como fallback.
  TileProvider get provider => _provider ?? NetworkTileProvider();
}
