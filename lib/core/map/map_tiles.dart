import 'dart:convert';

/// Tiles de mapa: OpenStreetMap como padrão primário gratuito,
/// com fallbacks automáticos para CARTO e Mapbox.
///
/// O pré-download e a navegação offline usam OpenStreetMap por padrão
/// para não consumir tokens privados. No [TileCache], os dados são
/// guardados de forma permanente (sem expiração), permanecendo até o
/// usuário decidir excluir a cidade/região.
class MapTiles {
  MapTiles._();

  /// 1. Provedor Principal Padrão: OpenStreetMap Oficial (Gratuito / Sem Token)
  static const String osmStandard =
      'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

  /// Token Mapbox padrão embarcado (fallback do 1º boot offline). A verdade mora
  /// no Supabase (`app_config.mapbox_token`) — rotacione por lá, sem update.
  static String _resolveDefaultToken() {
    const envToken = String.fromEnvironment('MAPBOX_TOKEN', defaultValue: '');
    if (envToken.isNotEmpty) return envToken;
    try {
      const b64 =
          'cGsuZXlKMUlqb2libUZ1YjI1aGJtODJNVE1pTENKaElqb2lZMjEyT0dSM2EyazVNSE50YVRKNWJ6ZDVlVEprYTNNNFlpSjkuSVBNdWQwLVJiSkpDWjdQQVhCaUNQdw==';
      return utf8.decode(base64.decode(b64));
    } catch (_) {
      return '';
    }
  }

  static final String _defaultToken = _resolveDefaultToken();

  static String? _mapboxOverride;

  /// Apenas [MapConfigService] e testes chamam.
  static void setMapboxToken(String? token) {
    _mapboxOverride =
        (token == null || token.trim().isEmpty) ? null : token.trim();
  }

  static String get _token =>
      _mapboxOverride ?? _defaultToken;

  /// Key da CARTO (vias): NUNCA hardcoded — vem do Supabase via
  /// [MapConfigService] (com cache local).
  static String? _cartoKey;

  /// Apenas [MapConfigService] e testes chamam.
  static void setCartoKey(String? key) {
    _cartoKey = (key == null || key.trim().isEmpty) ? null : key.trim();
  }

  static String? get cartoKey => _cartoKey;

  static const String _stylesBase =
      'https://api.mapbox.com/styles/v1/mapbox';

  static String _style(String styleId) =>
      '$_stylesBase/$styleId/tiles/256/{z}/{x}/{y}{r}?access_token=$_token';

  /// CARTO raster (Positron 'light_all' / Dark Matter 'dark_all')
  /// Baseado 100% em dados do OpenStreetMap, com estilização minimalista e moderna estilo Uber.
  static String _carto(String style, String? key) =>
      key != null && key.isNotEmpty
          ? 'https://basemaps.cartocdn.com/rastertiles/$style/{z}/{x}/{y}{r}.png?key=$key'
          : 'https://basemaps.cartocdn.com/rastertiles/$style/{z}/{x}/{y}{r}.png';

  /// Vias, tema claro: CARTO Positron (estilo Uber - limpo, minimalista, fundo off-white)
  static String get roads => _carto('light_all', _cartoKey);

  /// Fallback de vias claras (se CARTO oscilar): OpenStreetMap padrão oficial
  static String get fallbackRoads => osmStandard;

  /// Vias, tema noturno: CARTO Dark Matter (estilo Uber Black - grafite elegante)
  static String get roadsDark => _carto('dark_all', _cartoKey);

  /// Fallback de vias escuras: OpenStreetMap padrão oficial
  static String get fallbackRoadsDark => osmStandard;

  /// URL padrão para Download Offline (Baixa os tiles limpos Positron/Dark Matter para sempre)
  static String get offlineDownloadUrl => _carto('light_all', _cartoKey);
  static String get offlineDownloadUrlDark => _carto('dark_all', _cartoKey);

  /// Satélite com rótulos de rua (Mapbox — melhor imagem).
  static String get satellite => _style('satellite-streets-v12');

  /// Fallback de satélite aberto (ArcGIS World Imagery - alta resolução, sem token)
  static const String satelliteFallback =
      'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';

  /// Atribuição exigida por licença
  static String get attribution =>
      '© OpenStreetMap contributors © CARTO';

  /// Satélite: imagem © Maxar + rótulos do OpenStreetMap.
  static const String attributionSatellite = '© Mapbox © Maxar © OpenStreetMap';
}
