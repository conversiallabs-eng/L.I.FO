/// Geometria do modo paisagem do mapa.
///
/// Em retrato o mapa ocupa a tela toda e o card das paradas é um bottom sheet
/// por cima dele. Em paisagem o painel fixa à esquerda (parada / lista) e o
/// mapa fica à direita — visão geral ou navegação ativa, como no Circuit.
///
/// Fica aqui, isolado da tela, porque é a parte que dá para testar sem montar
/// o dashboard inteiro (que depende de GPS, Supabase e banco).
class MapSplitLayout {
  MapSplitLayout._();

  /// Fração da largura da tela ocupada pelo painel de paradas.
  static const double panelRatio = 0.38;

  /// Piso: em tela estreita o painel não pode virar uma tira ilegível.
  static const double minPanelWidth = 320;

  /// Teto: em tablet o mapa ainda precisa ser a maior parte da tela.
  static const double maxPanelWidth = 460;

  /// Painel lateral em qualquer modo, desde que a tela esteja deitada.
  static bool showsSidePanel({
    required bool isLandscape,
    bool isNavigating = false,
  }) =>
      isLandscape;

  /// Largura do painel lateral para uma dada largura de tela.
  static double panelWidth(double screenWidth) =>
      (screenWidth * panelRatio).clamp(minPanelWidth, maxPanelWidth);
}
