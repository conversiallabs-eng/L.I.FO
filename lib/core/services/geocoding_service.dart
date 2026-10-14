import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

/// Busca real de endereços via Nominatim (OpenStreetMap) — grátis, sem API key.
/// Exige apenas User-Agent identificando o app (política de uso do OSM).
class GeocodingResult {
  final String displayName;
  final double latitude;
  final double longitude;

  const GeocodingResult({
    required this.displayName,
    required this.latitude,
    required this.longitude,
  });
}

class GeocodingService {
  static const Duration _timeout = Duration(seconds: 8);
  static const Duration _fastTimeout = Duration(seconds: 12);

  /// Cache da sessão: endereços repetidos no mesmo manifesto não recarregam.
  final Map<String, GeocodingResult?> _batchCache = {};

  Future<List<GeocodingResult>> searchAddress(String query) async {
    final trimmed = query.trim();
    if (trimmed.length < 4) return [];

    final uri = Uri.https('nominatim.openstreetmap.org', '/search', {
      'q': trimmed,
      'format': 'jsonv2',
      'limit': '6',
      'countrycodes': 'br',
      'accept-language': 'pt-BR',
    });

    try {
      final response = await http.get(uri, headers: {
        'User-Agent': 'com.lifo.app (LIFO Logistics)',
        'Accept': 'application/json',
      }).timeout(_timeout);

      if (response.statusCode != 200) return [];

      final List<dynamic> data = jsonDecode(response.body) as List<dynamic>;
      return data.map((item) {
        final map = item as Map<String, dynamic>;
        return GeocodingResult(
          displayName: map['display_name'] as String? ?? trimmed,
          latitude: double.tryParse(map['lat'] as String? ?? '') ?? 0,
          longitude: double.tryParse(map['lon'] as String? ?? '') ?? 0,
        );
      }).where((r) => r.latitude != 0 && r.longitude != 0).toList();
    } catch (_) {
      // Offline ou timeout — retorna vazio, a UI mostra dica de conexão.
      return [];
    }
  }

  /// Geocodifica várias consultas em sequência respeitando a política do
  /// Nominatim (máx. 1 req/s). Retorna null nas que falharem.
  Future<List<GeocodingResult?>> geocodeBatch(
    List<String> queries, {
    void Function(int done, int total)? onProgress,
    bool Function()? shouldCancel,
  }) async {
    final results = <GeocodingResult?>[];
    for (int i = 0; i < queries.length; i++) {
      if (shouldCancel?.call() == true) {
        results.addAll(List.filled(queries.length - i, null));
        break;
      }
      if (i > 0) {
        await Future.delayed(const Duration(milliseconds: 1100));
      }
      if (shouldCancel?.call() == true) {
        results.addAll(List.filled(queries.length - i, null));
        break;
      }
      final found = await searchAddress(queries[i]);
      results.add(found.isNotEmpty ? found.first : null);
      onProgress?.call(i + 1, queries.length);
    }
    return results;
  }

  /// Busca única ultrarrápida no Photon (Komoot/OSM) — sem key, feito para
  /// lote: respostas pequenas e tolerante a paralelismo. Opcionalmente
  /// enviesa para perto do GPS (lat/lng) para desambiguar ruas repetidas.
  Future<GeocodingResult?> photonSearch(
    String query, {
    double? biasLat,
    double? biasLng,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return null;

    final params = <String, String>{
      'q': trimmed,
      'limit': '3',
      // Sem 'lang': o Photon só aceita default/de/en/fr e devolve 400 para 'pt'.
      if (biasLat != null && biasLng != null) ...{
        'lat': biasLat.toString(),
        'lon': biasLng.toString(),
      },
    };
    final uri = Uri.https('photon.komoot.io', '/api/', params);

    try {
      final response = await http.get(uri, headers: {
        'User-Agent': 'com.lifo.app (LIFO Logistics)',
        'Accept': 'application/json',
      }).timeout(_fastTimeout);

      if (response.statusCode != 200) return null;
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final features = data['features'] as List<dynamic>?;
      if (features == null || features.isEmpty) return null;

      // Prefere resultado no Brasil; cai para o primeiro como fallback.
      Map<String, dynamic>? best;
      Map<String, dynamic>? first;
      for (final f in features) {
        final feature = f as Map<String, dynamic>;
        first ??= feature;
        final props = feature['properties'] as Map<String, dynamic>? ?? {};
        if ((props['countrycode'] as String?)?.toUpperCase() == 'BR') {
          best = feature;
          break;
        }
      }
      final chosen = best ?? first;
      if (chosen == null) return null;

      final geometry = chosen['geometry'] as Map<String, dynamic>?;
      final coords = geometry?['coordinates'] as List<dynamic>?;
      if (coords == null || coords.length < 2) return null;

      final props = chosen['properties'] as Map<String, dynamic>? ?? {};
      final street = props['street'] as String?;
      final number = props['housenumber'] as String?;
      final name = props['name'] as String?;
      final city = props['city'] as String? ?? props['locality'] as String?;
      final label = [
        if (street != null) (number != null ? '$street, $number' : street),
        if (street == null && name != null) name,
        ?city,
      ].join(' — ');

      return GeocodingResult(
        displayName: label.isNotEmpty ? label : trimmed,
        latitude: (coords[1] as num).toDouble(),
        longitude: (coords[0] as num).toDouble(),
      );
    } catch (_) {
      return null;
    }
  }

  /// Lote ultrarrápido: deduplica consultas repetidas, dispara até 8 buscas
  /// em paralelo e usa o cache da sessão. ~100 endereços em poucos segundos.
  Future<List<GeocodingResult?>> geocodeBatchFast(
    List<String> queries, {
    double? biasLat,
    double? biasLng,
    void Function(int done, int total, GeocodingResult? last)? onProgress,
    bool Function()? shouldCancel,
  }) async {
    // Dedup: mesmo endereço aparece uma vez na rede, replica no resultado.
    final unique = <String>[];
    final slotOf = <String, int>{};
    final mapTo = List<int>.filled(queries.length, 0);
    for (int i = 0; i < queries.length; i++) {
      final q = queries[i];
      var slot = slotOf[q];
      if (slot == null) {
        slot = unique.length;
        slotOf[q] = slot;
        unique.add(q);
      }
      mapTo[i] = slot;
    }

    final results = List<GeocodingResult?>.filled(unique.length, null);
    final pending = <int>[];
    for (int u = 0; u < unique.length; u++) {
      if (_batchCache.containsKey(unique[u])) {
        results[u] = _batchCache[unique[u]];
      } else {
        pending.add(u);
      }
    }

    int done = unique.length - pending.length;
    void report(GeocodingResult? last) =>
        onProgress?.call(done, unique.length, last);

    var cursor = 0;
    Future<void> worker() async {
      while (true) {
        if (shouldCancel?.call() == true) return;
        int u;
        // Fila simples: cada worker pega o próximo índice livre.
        if (cursor >= pending.length) return;
        u = pending[cursor];
        cursor++;
        final found = await photonSearch(
          unique[u],
          biasLat: biasLat,
          biasLng: biasLng,
        );
        if (shouldCancel?.call() == true) return;
        results[u] = found;
        _batchCache[unique[u]] = found;
        done++;
        report(found);
      }
    }

    const concurrency = 8;
    await Future.wait([for (int w = 0; w < concurrency; w++) worker()]);
    report(null);

    return [for (final m in mapTo) results[m]];
  }
}
