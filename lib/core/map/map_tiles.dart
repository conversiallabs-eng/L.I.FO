/// Tiles de mapa servidos pela Mapbox (Static Tiles API, XYZ raster).
///
/// A troca pela CARTO foi revertida: o endpoint keyless dela passou a
/// responder "API KEY REQUIRED" em produção (print de 15/10). Em 2026 não
/// há raster gratuito sem key confiável (Carto/Stadia/MapTiler exigem key;
/// OSM público proíbe uso pesado; ArcGIS é best-effort) — e o consumo real
/// cabe folgado na cota grátis (200 mil requests/mês). Mantêm-se os vetos:
///
/// - `mt{s}.google.com/vt` — endpoint não-oficial, fora do ToS do Google;
/// - `tile.openstreetmap.org` — proíbe uso pesado e é bloqueado sem aviso;
/// - `server.arcgisonline.com` — serviço público ArcGIS, best-effort.
///
/// O token é do tipo `pk.` (público, feito para ir embutido no app). Para
/// reduzir abuso, restrinja-o no painel da Mapbox (Account → Tokens → URL
/// restrictions) e/ou passe a servi-lo por um proxy próprio.
///
/// Nota sobre o cache em disco: [TileCache] guarda por URL, então trocar de
/// estilo ou de token troca a chave do cache — os tiles antigos simplesmente
/// deixam de ser lidos, sem precisar limpar nada.
class MapTiles {
  MapTiles._();

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
  /// [MapConfigService] (com cache local). Nula = fallback Mapbox.
  static String? _cartoKey;

  /// Apenas [MapConfigService] e testes chamam.
  static void setCartoKey(String? key) {
    _cartoKey = (key == null || key.trim().isEmpty) ? null : key.trim();
  }

  static String? get cartoKey => _cartoKey;

  static const String _stylesBase =
      'https://api.mapbox.com/styles/v1/mapbox';

  /// `{r}` vira `@2x` quando a camada liga `retinaMode` (tile real de 512 px,
  /// rótulo no tamanho certo — diferente do @2x do Google, que encolhia o
  /// nome das ruas). Fica no template mesmo nas camadas que hoje não usam
  /// retina, para ligar depois sem mexer na URL.
  static String _style(String styleId) =>
      '$_stylesBase/$styleId/tiles/256/{z}/{x}/{y}{r}?access_token=$_token';

  /// CARTO raster com key (formato oficial do e-mail da key).
  static String _carto(String style, String key) =>
      'https://basemaps.cartocdn.com/rastertiles/$style/{z}/{x}/{y}{r}.png?key=$key';

  /// Vias, tema claro: CARTO Voyager com key; sem key, Mapbox streets-v12.
  static String get roads =>
      _cartoKey == null ? _style('streets-v12') : _carto('voyager', _cartoKey!);

  /// Vias, tema noturno: CARTO Dark Matter com key; sem key, Mapbox dark-v11.
  static String get roadsDark =>
      _cartoKey == null ? _style('dark-v11') : _carto('dark_all', _cartoKey!);

  /// Satélite com rótulos de rua (sempre Mapbox — melhor imagem).
  static String get satellite => _style('satellite-streets-v12');

  /// Atribuição exigida por licença (acompanha o provedor das vias).
  static String get attribution => _cartoKey == null
      ? '© Mapbox © OpenStreetMap'
      : '© OpenStreetMap contributors © CARTO';

  /// Satélite: imagem © Maxar + rótulos do OpenStreetMap.
  static const String attributionSatellite = '© Mapbox © Maxar © OpenStreetMap';
}
