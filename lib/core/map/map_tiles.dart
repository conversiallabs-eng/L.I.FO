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

  /// Token Mapbox embarcado (fallback do 1º boot offline). A verdade mora
  /// no Supabase (`app_config.mapbox_token`) — rotacione por lá, sem update.
  static const String _defaultToken =
      String.fromEnvironment('MAPBOX_TOKEN', defaultValue: '');

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

  /// CARTO raster (Voyager / Dark Matter)
  static String _carto(String style, String? key) =>
      key != null && key.isNotEmpty
          ? 'https://basemaps.cartocdn.com/rastertiles/$style/{z}/{x}/{y}{r}.png?key=$key'
          : 'https://basemaps.cartocdn.com/rastertiles/$style/{z}/{x}/{y}{r}.png';

  /// Vias, tema claro: Padrão OpenStreetMap (Fallback: CARTO Voyager ou Mapbox Streets)
  static String get roads => osmStandard;

  /// Fallback de vias claras caso o OSM falhe:
  static String get fallbackRoads =>
      _cartoKey != null ? _carto('voyager', _cartoKey) : _style('streets-v12');

  /// Vias, tema noturno (estilo Uber):
  /// CARTO Dark Matter (se key) ou OpenStreetMap com filtro de matriz escura; fallback Mapbox dark-v11.
  static String get roadsDark =>
      _cartoKey != null ? _carto('dark_all', _cartoKey) : osmStandard;

  /// Fallback de vias escuras caso o primário falhe:
  static String get fallbackRoadsDark => _style('dark-v11');

  /// URL padrão para Download Offline (OpenStreetMap sem expiração e sem limites)
  static String get offlineDownloadUrl => osmStandard;
  static String get offlineDownloadUrlDark =>
      _cartoKey != null ? _carto('dark_all', _cartoKey) : osmStandard;

  /// Satélite com rótulos de rua (Mapbox — melhor imagem).
  static String get satellite => _style('satellite-streets-v12');

  /// Atribuição exigida por licença
  static String get attribution =>
      '© OpenStreetMap contributors © CARTO © Mapbox';

  /// Satélite: imagem © Maxar + rótulos do OpenStreetMap.
  static const String attributionSatellite = '© Mapbox © Maxar © OpenStreetMap';
}
