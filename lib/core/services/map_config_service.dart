import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../map/map_tiles.dart';
import 'app_headers_service.dart';

/// Chaves de mapa em runtime (Fase custo-zero): a key da CARTO fica no
/// Supabase (`app_config.carto_key`) e NUNCA hardcoded no APK — descompilar
/// o app não revela nada. Fluxo:
///   1. lê o cache local (instantâneo, vale offline);
///   2. com internet, repuxa do servidor (permite rotacionar sem update).
/// Sem key (1º boot offline): ruas caem no fallback Mapbox.
class MapConfigService {
  static final MapConfigService instance = MapConfigService._internal();
  MapConfigService._internal();

  static const String _kCartoCacheKey = 'lifo_carto_key_v1';
  static const String _kMapboxCacheKey = 'lifo_mapbox_token_v1';

  String? get cartoKey => MapTiles.cartoKey;

  /// Chamado no boot (com timeout curto por fora). Nunca lança.
  /// Repuxa CARTO + Mapbox; sem rede vale o cache (ou os fallbacks).
  Future<void> refresh() async {
    // 1. Cache local primeiro (offline-first).
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedCarto = prefs.getString(_kCartoCacheKey);
      if (cachedCarto != null && cachedCarto.isNotEmpty) {
        MapTiles.setCartoKey(cachedCarto);
      }
      final cachedMapbox = prefs.getString(_kMapboxCacheKey);
      if (cachedMapbox != null && cachedMapbox.isNotEmpty) {
        MapTiles.setMapboxToken(cachedMapbox);
      }
    } catch (_) {}

    // 2. Servidor quando dá (Supabase já inicializado no boot).
    try {
      final rows = await Supabase.instance.client
          .from('app_config')
          .select('key, value')
          .inFilter('key', ['carto_key', 'mapbox_token'])
          .timeout(const Duration(seconds: 4));
      final map = {
        for (final r in (rows as List))
          (r['key'] as String): (r['value'] as String? ?? '').trim(),
      };
      // Token Mapbox rotacionável (aplica direto; sem sonda — o satélite
      // só baixa sob demanda e o fallback é o próprio embarcado).
      final mbToken = map['mapbox_token'] ?? '';
      if (mbToken.isNotEmpty) {
        MapTiles.setMapboxToken(mbToken);
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(_kMapboxCacheKey, mbToken);
        } catch (_) {}
      }
      final key = (map['carto_key'] ?? '').trim();
      if (key.isNotEmpty) {
        // Sonda: 1 tile real antes de confiar. Se a key for recusada
        // (ex.: restrição de app desconfigurada na CARTO), volta ao
        // fallback Mapbox em vez de mapa apagado.
        if (await _probeCartoKey(key)) {
          MapTiles.setCartoKey(key);
          try {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString(_kCartoCacheKey, key);
          } catch (_) {}
          debugPrint('MapConfig: key CARTO ativa (servidor).');
        } else {
          MapTiles.setCartoKey(null);
          debugPrint('MapConfig: key recusada — fallback Mapbox.');
        }
      } else {
        debugPrint('MapConfig: sem key no servidor, segue fallback.');
      }
    } catch (_) {
      // Offline ou tabela ausente: vale o cache (ou o fallback Mapbox).
    }
  }

  /// Baixa 1 tile de teste (Floripa centro, z10/374/593) COM os headers
  /// do app. 200 + imagem = key válida (inclusive com trava de mobile app).
  /// 401/403/texto = restrição ou key inválida. Timeout curto p/ não
  /// prender o boot.
  Future<bool> _probeCartoKey(String key) async {
    try {
      final url = Uri.parse(
        'https://basemaps.cartocdn.com/rastertiles/light_all/10/374/593.png?key=$key',
      );
      final res = await http.get(
        url,
        headers: AppHeadersService.instance.tileHeadersSync,
      ).timeout(const Duration(seconds: 6));
      final ct = res.headers['content-type'] ?? '';
      final ok = res.statusCode == 200 && ct.contains('image');
      if (!ok) {
        debugPrint(
            'MapConfig: probe CARTO ${res.statusCode} ($ct) — restrição?');
      }
      return ok;
    } catch (e) {
      debugPrint('MapConfig: probe CARTO falhou ($e).');
      return false;
    }
  }
}
