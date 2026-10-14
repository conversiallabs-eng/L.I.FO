import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class _TutorialStep {
  final IconData icon;
  final List<Color> gradient;
  final String title;
  final String body;
  final String tip;

  const _TutorialStep({
    required this.icon,
    required this.gradient,
    required this.title,
    required this.body,
    required this.tip,
  });
}

const _steps = [
  _TutorialStep(
    icon: Icons.local_shipping_rounded,
    gradient: [Color(0xFF2563EB), Color(0xFF0284C7)],
    title: 'Bem-vindo ao LIFO!',
    body:
        'O LIFO monta sua rota de entregas na ordem ideal e diz exatamente onde cada volume vai dentro do baú — pela lógica LIFO: o último que entra é o primeiro que sai.',
    tip: 'Arraste para o lado e veja o passo a passo.',
  ),
  _TutorialStep(
    icon: Icons.upload_file_outlined,
    gradient: [Color(0xFF059669), Color(0xFF10B981)],
    title: '1. Importe seu manifesto',
    body:
        'Toque no menu ⋯ e depois em “Importar Manifesto”. Vale planilha CSV ou Excel — inclusive exportadas da Shopee, Mercado Livre e Amazon.\n\nDeixe o GPS ligado: a parada 1 é sempre a mais perto de você.',
    tip: 'Sem planilha? Use “Nova Parada” e cadastre na mão.',
  ),
  _TutorialStep(
    icon: Icons.history_rounded,
    gradient: [Color(0xFF7C3AED), Color(0xFFA855F7)],
    title: '2. Suas rotas não se perdem',
    body:
        'Cada importação vira uma versão guardada em “Versões da Rota” (menu ⋯). Dá para renomear, voltar para uma versão antiga e mandar reotimizar tudo a partir do GPS com “Otimizar Rota”.',
    tip: 'Nada é apagado sem confirmação.',
  ),
  _TutorialStep(
    icon: Icons.qr_code_scanner_rounded,
    gradient: [Color(0xFFEA580C), Color(0xFFF59E0B)],
    title: '3. Bipe a carga pela etiqueta',
    body:
        'Menu ⋯ → “Bipar Carga”: aponte a câmera para o código de barras da etiqueta. O app marca o volume como carregado e mostra em qual parada ele desce e em que posição do baú ele vai.',
    tip: 'Bipou errado? Dá para desfazer na hora.',
  ),
  _TutorialStep(
    icon: Icons.inventory_2_outlined,
    gradient: [Color(0xFF0284C7), Color(0xFF22D3EE)],
    title: '4. Carregue o baú na ordem certa',
    body:
        'Menu ⋯ → “Carregar Veículo”: a lista de carregamento é o inverso da entrega — o que desce por último entra primeiro, lá no fundo. O volume da parada 1 fica na porta, pronto para sair.',
    tip: 'Siga a ordem e nunca mais descarregue o baú à toa.',
  ),
  _TutorialStep(
    icon: Icons.navigation_rounded,
    gradient: [Color(0xFF1D4ED8), Color(0xFF60A5FA)],
    title: '5. Navegue sem errar',
    body:
        'Toque em “Navegar” no card da parada. O card arrasta para o lado para trocar de parada, o HUD azul anuncia a próxima curva com a distância real de rua, a voz guia o caminho e a seta azul mantém a câmera atrás do cursor — arrastou o mapa? Ela volta sozinha em segundos.',
    tip: 'Toque no HUD azul para ver a manobra de novo.',
  ),
  _TutorialStep(
    icon: Icons.verified_rounded,
    gradient: [Color(0xFF16A34A), Color(0xFF4ADE80)],
    title: '6. Conta e assinatura',
    body:
        'Você começa com 30 dias de trial. Renove via PIX em “Minha Conta”, revise seus dados por lá (o CPF precisa ser válido, senão o pagamento é recusado) e boa rota!',
    tip: 'Precisa rever? Menu lateral → “?” → ver tutorial de novo.',
  ),
];

/// Tutorial paginado de primeiro login (fullscreen, com animações suaves).
class AppTutorialScreen extends StatefulWidget {
  const AppTutorialScreen({super.key});

  static Future<void> open(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const AppTutorialScreen(),
        fullscreenDialog: true,
      ),
    );
  }

  @override
  State<AppTutorialScreen> createState() => _AppTutorialScreenState();
}

class _AppTutorialScreenState extends State<AppTutorialScreen> {
  final PageController _pages = PageController();
  int _index = 0;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _go(int i) {
    HapticFeedback.selectionClick();
    _pages.animateToPage(
      i,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC);
    final titleColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
    final isLast = _index == _steps.length - 1;

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        elevation: 0,
        leading: _index > 0
            ? IconButton(
                icon: Icon(Icons.arrow_back, color: titleColor),
                onPressed: () => _go(_index - 1),
              )
            : null,
        actions: [
          if (!isLast)
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text(
                'Pular',
                style: TextStyle(
                  color: Color(0xFF2563EB),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: PageView.builder(
                controller: _pages,
                physics: const BouncingScrollPhysics(
                  parent: AlwaysScrollableScrollPhysics(),
                ),
                onPageChanged: (i) {
                  HapticFeedback.lightImpact();
                  setState(() => _index = i);
                },
                itemCount: _steps.length,
                itemBuilder: (_, i) => _StepPage(
                  key: ValueKey('tutorial-step-$i'),
                  step: _steps[i],
                  pageLabel: '${i + 1} de ${_steps.length}',
                  titleColor: titleColor,
                  subColor: subColor,
                  isDark: isDark,
                ),
              ),
            ),
            // Dots
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (int i = 0; i < _steps.length; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOutCubic,
                    width: i == _index ? 26 : 8,
                    height: 8,
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    decoration: BoxDecoration(
                      color: i == _index
                          ? const Color(0xFF2563EB)
                          : const Color(0xFF94A3B8).withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 18),
            // CTA
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2563EB),
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  onPressed: () {
                    if (isLast) {
                      HapticFeedback.mediumImpact();
                      Navigator.of(context).pop();
                    } else {
                      _go(_index + 1);
                    }
                  },
                  child: Text(
                    isLast ? 'Começar agora' : 'Continuar',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}

class _StepPage extends StatelessWidget {
  final _TutorialStep step;
  final String pageLabel;
  final Color titleColor;
  final Color subColor;
  final bool isDark;

  const _StepPage({
    super.key,
    required this.step,
    required this.pageLabel,
    required this.titleColor,
    required this.subColor,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      padding: const EdgeInsets.fromLTRB(28, 12, 28, 16),
      children: [
        Center(
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0.7, end: 1.0),
            duration: const Duration(milliseconds: 450),
            curve: Curves.easeOutBack,
            builder: (_, scale, child) =>
                Transform.scale(scale: scale, child: child),
            child: Container(
              width: 108,
              height: 108,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: step.gradient,
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(30),
                boxShadow: [
                  BoxShadow(
                    color: step.gradient.first.withValues(alpha: 0.4),
                    blurRadius: 24,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Icon(step.icon, size: 52, color: Colors.white),
            ),
          ),
        ),
        const SizedBox(height: 26),
        Text(
          step.title,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: titleColor,
            fontSize: 24,
            fontWeight: FontWeight.w900,
            letterSpacing: -0.4,
            height: 1.2,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          step.body,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: subColor,
            fontSize: 14,
            height: 1.55,
          ),
        ),
        const SizedBox(height: 18),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xFF2563EB).withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: const Color(0xFF2563EB).withValues(alpha: 0.25),
            ),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.lightbulb_outline,
                size: 18,
                color: Color(0xFF2563EB),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  step.tip,
                  style: TextStyle(
                    color: titleColor,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Center(
          child: Text(
            pageLabel,
            style: TextStyle(
              color: subColor,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}
