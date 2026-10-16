import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import '../database/app_database.dart';
import '../map/map_tiles.dart';
import '../map/tile_cache.dart';
import 'app_headers_service.dart';

/// User-Agent padronizado (Mapbox + Nominatim exigem identificação).
const String kLifoUserAgent = 'LifoApp/1.0 (com.lifo.app)';

/// Limites do pré-download para não explodir disco/memória do celular.
/// z10–11 são contexto (visão da rota toda, poucas dezenas de tiles);
/// z12–16 é a navegação rua a rua.
const int kOfflineMinZoom = 10;
const int kOfflineMaxZoom = 16;
const int kOfflineMaxTilesPerRegion = 20000;

/// Região de mapa offline (uma cidade ou o bbox da rota atual).
class OfflineRegion {
  final String cityKey;
  final String displayName;
  final double minLat;
  final double maxLat;
  final double minLng;
  final double maxLng;
  final int minZoom;
  final int maxZoom;
  final int tilesTotal;
  final int tilesDone;
  final String status; // pending|downloading|complete|partial
  final DateTime updatedAt;

  const OfflineRegion({
    required this.cityKey,
    required this.displayName,
    required this.minLat,
    required this.maxLat,
    required this.minLng,
    required this.maxLng,
    required this.minZoom,
    required this.maxZoom,
    required this.tilesTotal,
    required this.tilesDone,
    required this.status,
    required this.updatedAt,
  });

  double get progress =>
      tilesTotal <= 0 ? 0 : (tilesDone / tilesTotal).clamp(0.0, 1.0);

  Map<String, Object?> toMap() => {
        'city_key': cityKey,
        'display_name': displayName,
        'min_lat': minLat,
        'max_lat': maxLat,
        'min_lng': minLng,
        'max_lng': maxLng,
        'min_zoom': minZoom,
        'max_zoom': maxZoom,
        'tiles_total': tilesTotal,
        'tiles_done': tilesDone,
        'status': status,
        'updated_at': updatedAt.toIso8601String(),
      };

  factory OfflineRegion.fromMap(Map<String, dynamic> m) => OfflineRegion(
        cityKey: m['city_key'] as String,
        displayName: m['display_name'] as String? ?? '',
        minLat: (m['min_lat'] as num).toDouble(),
        maxLat: (m['max_lat'] as num).toDouble(),
        minLng: (m['min_lng'] as num).toDouble(),
        maxLng: (m['max_lng'] as num).toDouble(),
        minZoom: (m['min_zoom'] as num?)?.toInt() ?? kOfflineMinZoom,
        maxZoom: (m['max_zoom'] as num?)?.toInt() ?? kOfflineMaxZoom,
        tilesTotal: (m['tiles_total'] as num?)?.toInt() ?? 0,
        tilesDone: (m['tiles_done'] as num?)?.toInt() ?? 0,
        status: m['status'] as String? ?? 'pending',
        updatedAt: DateTime.tryParse(m['updated_at'] as String? ?? '') ??
            DateTime.now(),
      );
}

class CityBoundingBox {
  final String displayName;
  final double minLat;
  final double maxLat;
  final double minLng;
  final double maxLng;

  const CityBoundingBox({
    required this.displayName,
    required this.minLat,
    required this.maxLat,
    required this.minLng,
    required this.maxLng,
  });
}

/// Pré-download de tiles Mapbox por cidade/bbox no MESMO Hive do mapa.
///
/// O download usa o Dio com interceptor de cache do [TileCache] — cada GET
/// popula o Hive, então o `TileLayer` lê offline sem mudar nada.
class OfflineMapService {
  static final OfflineMapService instance = OfflineMapService._internal();
  OfflineMapService._internal();

  bool _running = false;
  bool get isDownloading => _running;

  String normalizeCityKey(String name) {
    var k = name.trim().toLowerCase();
    const accents = {
      'á': 'a',
      'à': 'a',
      'â': 'a',
      'ã': 'a',
      'é': 'e',
      'ê': 'e',
      'í': 'i',
      'ó': 'o',
      'ô': 'o',
      'õ': 'o',
      'ú': 'u',
      'ü': 'u',
      'ç': 'c',
    };
    accents.forEach((a, b) => k = k.replaceAll(a, b));
    k = k.replaceAll(RegExp(r'[^a-z0-9]+'), '-');
    return k.replaceAll(RegExp(r'^-+|-+$'), '');
  }

  // ─── BBOX DE CIDADE VIA NOMINATIM ──────────────────────────────────────

  /// Bbox da cidade via Nominatim (grátis, sem key). Ex.: "Florianópolis, SC".
  Future<CityBoundingBox?> fetchCityBoundingBox(String cityQuery) async {
    final q = cityQuery.trim();
    if (q.length < 3) return null;
    final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
      'q': q,
      'format': 'json',
      'limit': '1',
      'countrycodes': 'br',
      'accept-language': 'pt-BR',
    });
    try {
      final res = await http.get(uri, headers: {
        'User-Agent': kLifoUserAgent,
        'Accept': 'application/json',
      }).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      final list = jsonDecode(res.body) as List<dynamic>;
      if (list.isEmpty) return null;
      final first = list.first as Map<String, dynamic>;
      final bbox = first['boundingbox'] as List<dynamic>?;
      if (bbox == null || bbox.length < 4) return null;
      final south = double.tryParse(bbox[0].toString());
      final north = double.tryParse(bbox[1].toString());
      final west = double.tryParse(bbox[2].toString());
      final east = double.tryParse(bbox[3].toString());
      if (south == null || north == null || west == null || east == null) {
        return null;
      }
      return CityBoundingBox(
        displayName: first['display_name'] as String? ?? q,
        minLat: min(south, north),
        maxLat: max(south, north),
        minLng: min(west, east),
        maxLng: max(west, east),
      );
    } catch (_) {
      return null;
    }
  }

  /// Nome da cidade atual via reverse geocode (para o botão "Baixar aqui").
  Future<String?> reverseGeocodeCity(double lat, double lng) async {
    final uri = Uri.https('nominatim.openstreetmap.org', '/reverse', {
      'lat': lat.toString(),
      'lon': lng.toString(),
      'format': 'json',
      'accept-language': 'pt-BR',
    });
    try {
      final res = await http.get(uri, headers: {
        'User-Agent': kLifoUserAgent,
        'Accept': 'application/json',
      }).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final addr = data['address'] as Map<String, dynamic>?;
      if (addr == null) return null;
      final city = (addr['city'] ?? addr['town'] ?? addr['village'] ??
              addr['municipality'] ?? addr['county'])
          as String?;
      final state = addr['state_code'] as String? ?? addr['state'] as String?;
      if (city == null || city.isEmpty) return null;
      if (state != null && state.isNotEmpty && state.length <= 3) {
        return '$city, $state';
      }
      return city;
    } catch (_) {
      return null;
    }
  }

  // ─── MATEMÁTICA DE TILES ─────────────────────────────────────────────

  int _lngToX(double lng, int z) =>
      (((lng + 180.0) / 360.0 * (1 << z))).floor();

  int _latToY(double lat, int z) {
    final rad = lat * pi / 180.0;
    final n = (1 << z).toDouble();
    final y = (1.0 - log(tan(rad) + 1.0 / cos(rad)) / pi) / 2.0 * n;
    return y.floor().clamp(0, (1 << z) - 1);
  }

  /// Todos os (z,x,y) do bbox. `includeDark=false` baixa só o claro.
  List<(int z, int x, int y)> enumerateTiles({
    required double minLat,
    required double maxLat,
    required double minLng,
    required double maxLng,
    required int minZoom,
    required int maxZoom,
  }) {
    final out = <(int z, int x, int y)>[];
    for (var z = minZoom; z <= maxZoom; z++) {
      var x0 = _lngToX(minLng, z);
      var x1 = _lngToX(maxLng, z);
      var y0 = _latToY(maxLat, z);
      var y1 = _latToY(minLat, z);
      if (x0 > x1) {
        final t = x0;
        x0 = x1;
        x1 = t;
      }
      if (y0 > y1) {
        final t = y0;
        y0 = y1;
        y1 = t;
      }
      final maxIdx = (1 << z) - 1;
      x0 = x0.clamp(0, maxIdx);
      x1 = x1.clamp(0, maxIdx);
      y0 = y0.clamp(0, maxIdx);
      y1 = y1.clamp(0, maxIdx);
      for (var x = x0; x <= x1; x++) {
        for (var y = y0; y <= y1; y++) {
          out.add((z, x, y));
        }
      }
    }
    return out;
  }

  int estimateTileCount({
    required double minLat,
    required double maxLat,
    required double minLng,
    required double maxLng,
    required int minZoom,
    required int maxZoom,
    required bool includeDark,
  }) {
    final n = enumerateTiles(
      minLat: minLat,
      maxLat: maxLat,
      minLng: minLng,
      maxLng: maxLng,
      minZoom: minZoom,
      maxZoom: maxZoom,
    ).length;
    final needsSeparateDark = includeDark && MapTiles.roadsDark != MapTiles.roads;
    return needsSeparateDark ? n * 2 : n;
  }

  // IGUAL ao TileLayer em tela (flutter_map, default): subdomains [a,b,c]
  // com (x+y)%. Se divergir, o Hive erra a chave e o tile baixa de novo.
  static const _subdomains = ['a', 'b', 'c'];

  /// Expande o template p/ URL real — A MESMA URL que o TileLayer pede em
  /// tela, para o Hive acertar o cache offline (mesma chave).
  String _tileUrl(String template, int z, int x, int y) {
    final s = _subdomains[(x + y) % _subdomains.length];
    return template
        .replaceAll('{s}', s)
        .replaceAll('{z}', z.toString())
        .replaceAll('{x}', x.toString())
        .replaceAll('{y}', y.toString())
        .replaceAll('{r}', '');
  }

  // ─── DOWNLOAD ────────────────────────────────────────────────────────

  /// Baixa a região (claro + escuro) com concorrência controlada e throttle.
  /// Atualiza o progresso no SQLite a cada 50 tiles. Não lança em erro de
  /// rede por tile — só marca `partial` no fim.
  Future<OfflineRegion> downloadRegion({
    required String cityKey,
    required String displayName,
    required double minLat,
    required double maxLat,
    required double minLng,
    required double maxLng,
    int minZoom = kOfflineMinZoom,
    int maxZoom = kOfflineMaxZoom,
    bool includeDark = true,
    void Function(int done, int total)? onProgress,
    bool Function()? shouldCancel,
  }) async {
    if (_running) {
      throw StateError('Já existe um download em andamento.');
    }
    _running = true;
    try {
      final tiles = enumerateTiles(
        minLat: minLat,
        maxLat: maxLat,
        minLng: minLng,
        maxLng: maxLng,
        minZoom: minZoom,
        maxZoom: maxZoom,
      );
      final urls = <String>[];
      final separateDark = includeDark && MapTiles.roadsDark != MapTiles.roads;
      for (final (z, x, y) in tiles) {
        urls.add(_tileUrl(MapTiles.roads, z, x, y));
        if (separateDark) urls.add(_tileUrl(MapTiles.roadsDark, z, x, y));
      }
      if (urls.length > kOfflineMaxTilesPerRegion * 2) {
        throw StateError(
          'Região muito grande (${urls.length} tiles). '
          'Aproxime o bbox ou baixe por cidade menor.',
        );
      }

      await AppDatabase.instance.upsertOfflineRegion({
        'city_key': cityKey,
        'display_name': displayName,
        'min_lat': minLat,
        'max_lat': maxLat,
        'min_lng': minLng,
        'max_lng': maxLng,
        'min_zoom': minZoom,
        'max_zoom': maxZoom,
        'tiles_total': urls.length,
        'tiles_done': 0,
        'status': 'downloading',
      });

      final dio = TileCache.instance.dioForPrefetch as Dio?;
      int done = 0;
      int failures = 0;

      // Fila controlada: lotes de 6 com 15ms entre lotes (evita estouro
      // de sockets no Android/iOS + respeita rate limit do Mapbox).
      const batchSize = 6;
      for (var i = 0; i < urls.length; i += batchSize) {
        if (shouldCancel?.call() == true) break;
        final batch = urls.sublist(
          i,
          min(i + batchSize, urls.length),
        );
        final results = await Future.wait(
          batch.map((u) => _fetchOne(u, dio)),
        );
        for (final ok in results) {
          done++;
          if (!ok) failures++;
        }
        onProgress?.call(done, urls.length);
        if (done % 50 == 0 || done == urls.length) {
          await AppDatabase.instance.updateOfflineRegionProgress(
            cityKey,
            tilesDone: done,
            status: 'downloading',
          );
        }
        await Future.delayed(const Duration(milliseconds: 15));
      }

      final cancelled = shouldCancel?.call() == true;
      final status = cancelled
          ? 'partial'
          : (failures > urls.length * 0.2 ? 'partial' : 'complete');
      await AppDatabase.instance.updateOfflineRegionProgress(
        cityKey,
        tilesDone: done,
        status: status,
      );
      final row =
          await AppDatabase.instance.getOfflineRegion(cityKey);
      debugPrint(
        'OfflineMap: $displayName → $done/${urls.length} tiles '
        '(falhas: $failures, status: $status)',
      );
      return OfflineRegion.fromMap(row!);
    } finally {
      _running = false;
    }
  }

  /// Um tile: via Dio com cache (popula o Hive) ou http puro como fallback.
  /// 404 = área sem rua nesse zoom (conta como ok para não travar).
  /// Headers do app junto (trava mobile da CARTO cobra pacote + cert).
  Future<bool> _fetchOne(String url, Dio? dio) async {
    final headers = AppHeadersService.instance.tileHeadersSync;
    // 1. Via Dio do TileCache — passa pelo interceptor e grava no Hive.
    if (dio != null) {
      try {
        final res = await dio
            .get<List<int>>(
              url,
              options: Options(
                responseType: ResponseType.bytes,
                headers: headers,
                sendTimeout: const Duration(seconds: 12),
                receiveTimeout: const Duration(seconds: 12),
              ),
            )
            .timeout(const Duration(seconds: 15));
        final code = res.statusCode ?? 0;
        return code == 200 || code == 304 || code == 404;
      } catch (_) {
        // Cai no fallback http abaixo (Dio pode estar fechado, etc).
      }
    }
    // 2. Fallback http puro (não popula o Hive, mas evita crash).
    try {
      final res = await http.get(
        Uri.parse(url),
        headers: headers,
      ).timeout(const Duration(seconds: 15));
      return res.statusCode == 200 || res.statusCode == 404;
    } catch (_) {
      return false;
    }
  }

  // ─── COBERTURA DA ROTA (F4 silencioso) ───────────────────────────────

  /// Garante tiles do bbox da rota + buffer (~2km) na região `rota-atual`.
  /// Chamado após import/otimização COM internet; sem rede retorna null.
  /// Roda em background (não bloqueia a UI) e só baixa o que falta — o que
  /// já está no Hive vira cache-hit instantâneo.
  Future<OfflineRegion?> ensureRouteCoverage(
    List<LatLng> points, {
    double bufferDeg = 0.02, // ~2km
    bool Function()? shouldCancel,
  }) async {
    if (points.isEmpty || _running) return null;
    double minLat = points.first.latitude;
    double maxLat = points.first.latitude;
    double minLng = points.first.longitude;
    double maxLng = points.first.longitude;
    for (final p in points) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    // Evita bbox degenerado (1 ponto só).
    const minSpan = 0.03; // ~3km
    if ((maxLat - minLat).abs() < minSpan) {
      final c = (minLat + maxLat) / 2;
      minLat = c - minSpan / 2;
      maxLat = c + minSpan / 2;
    }
    if ((maxLng - minLng).abs() < minSpan) {
      final c = (minLng + maxLng) / 2;
      minLng = c - minSpan / 2;
      maxLng = c + minSpan / 2;
    }
    minLat -= bufferDeg;
    maxLat += bufferDeg;
    minLng -= bufferDeg;
    maxLng += bufferDeg;

    // Cap de segurança: bbox gigante (estado inteiro) não baixa silencioso.
    final estimate = estimateTileCount(
      minLat: minLat,
      maxLat: maxLat,
      minLng: minLng,
      maxLng: maxLng,
      minZoom: kOfflineMinZoom,
      maxZoom: kOfflineMaxZoom,
      includeDark: true,
    );
    if (estimate > 15000) {
      debugPrint('OfflineMap: bbox da rota grande demais ($estimate), pulando.');
      return null;
    }

    try {
      return await downloadRegion(
        cityKey: 'rota-atual',
        displayName: 'Rota atual (auto)',
        minLat: minLat,
        maxLat: maxLat,
        minLng: minLng,
        maxLng: maxLng,
        shouldCancel: shouldCancel,
      );
    } catch (e) {
      debugPrint('OfflineMap: cobertura da rota falhou: $e');
      return null;
    }
  }

  Future<List<OfflineRegion>> listRegions() async {
    final rows = await AppDatabase.instance.getOfflineRegions();
    return rows.map(OfflineRegion.fromMap).toList();
  }
}
