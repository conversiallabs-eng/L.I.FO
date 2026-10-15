import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

enum LegalDocType { terms, privacy }

class LegalDocumentScreen extends StatefulWidget {
  final LegalDocType initialType;

  const LegalDocumentScreen({
    super.key,
    this.initialType = LegalDocType.terms,
  });

  static Future<void> openTerms(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const LegalDocumentScreen(initialType: LegalDocType.terms),
      ),
    );
  }

  static Future<void> openPrivacy(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => const LegalDocumentScreen(initialType: LegalDocType.privacy),
      ),
    );
  }

  static Future<void> open(BuildContext context, {LegalDocType initialType = LegalDocType.terms}) {
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LegalDocumentScreen(initialType: initialType),
      ),
    );
  }

  @override
  State<LegalDocumentScreen> createState() => _LegalDocumentScreenState();
}

class _LegalDocumentScreenState extends State<LegalDocumentScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  static const String _termsUrl = 'https://lifo.com.br/termos.html';
  static const String _privacyUrl = 'https://lifo.com.br/privacidade.html';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.initialType == LegalDocType.terms ? 0 : 1,
    );
    _tabController.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _openInBrowser() async {
    final url = _tabController.index == 0 ? _termsUrl : _privacyUrl;
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Acesse: $url'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC);
    final cardBg = isDark ? const Color(0xFF1E293B) : Colors.white;
    final borderColor = isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0);
    final titleColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final bodyColor = isDark ? const Color(0xFFCBD5E1) : const Color(0xFF334155);
    final subColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        title: Text(
          _tabController.index == 0 ? 'Termos de Uso' : 'Política de Privacidade',
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w700,
            color: titleColor,
          ),
        ),
        centerTitle: true,
        backgroundColor: cardBg,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: titleColor),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          IconButton(
            tooltip: 'Abrir no navegador',
            icon: const Icon(Icons.open_in_browser, color: Color(0xFF2563EB)),
            onPressed: _openInBrowser,
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Container(
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: borderColor)),
            ),
            child: TabBar(
              controller: _tabController,
              indicatorColor: const Color(0xFF2563EB),
              indicatorWeight: 3,
              labelColor: const Color(0xFF2563EB),
              unselectedLabelColor: subColor,
              labelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
              unselectedLabelStyle: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13.5),
              tabs: const [
                Tab(text: 'Termos de Uso'),
                Tab(text: 'Privacidade (LGPD)'),
              ],
            ),
          ),
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildTermsView(cardBg, borderColor, titleColor, bodyColor, subColor),
          _buildPrivacyView(cardBg, borderColor, titleColor, bodyColor, subColor),
        ],
      ),
    );
  }

  Widget _buildTermsView(
    Color cardBg,
    Color borderColor,
    Color titleColor,
    Color bodyColor,
    Color subColor,
  ) {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      children: [
        _buildHeroCard(
          cardBg: cardBg,
          borderColor: borderColor,
          title: 'Termos e Condições Gerais',
          subtitle: 'Última atualização: 15 de outubro de 2026',
          badgeText: 'Contrato de Uso de Software',
          body: 'O L.I.F.O. é uma ferramenta de tecnologia desenvolvida para auxiliar entregadores na conferência, organização física de pacotes no baú e navegação de rotas. Ao utilizar nossos serviços, você concorda integralmente com estes termos.',
        ),
        const SizedBox(height: 14),
        _buildSectionCard(
          cardBg: cardBg,
          borderColor: borderColor,
          titleColor: titleColor,
          bodyColor: bodyColor,
          num: '01',
          title: 'Objeto e Funcionalidades',
          items: const [
            'Importação de manifestos de entrega em CSV, Excel ou TXT.',
            'Leitor óptico de código de barras para conferência rápida de pacotes.',
            'Algoritmo espacial LIFO: organiza o carregamento para que a primeira parada fique na porta do baú e a última no fundo.',
            'Roteirização e navegação offline-first para funcionamento contínuo sem sinal de celular.',
            'Sincronização em nuvem e versionamento do histórico de rotas.',
          ],
        ),
        _buildSectionCard(
          cardBg: cardBg,
          borderColor: borderColor,
          titleColor: titleColor,
          bodyColor: bodyColor,
          num: '02',
          title: 'Cadastro e Requisitos',
          items: const [
            'Usuário deve ter idade mínima de 18 anos e plena capacidade civil.',
            'Informações cadastrais devem ser exatas e mantidas atualizadas.',
            'Credenciais de acesso (senha ou Google) são pessoais e intransferíveis.',
          ],
        ),
        _buildSectionCard(
          cardBg: cardBg,
          borderColor: borderColor,
          titleColor: titleColor,
          bodyColor: bodyColor,
          num: '03',
          title: 'Planos e Pagamentos via Pix',
          items: const [
            'Trial Grátis de 30 dias: sem cartão de crédito e sem cobrança automática ao expirar.',
            'Plano Mensal Pix: R\$ 19,90 por mês sem renovação forçada ou fidelidade.',
            'Plano Anual Pix: R\$ 200,00 por ano com desconto progressivo.',
            'As cobranças são processadas exclusivamente via Pix através do parceiro homologado Asaas Gestão Financeira.',
          ],
        ),
        _buildAlertCard(
          title: '🤝 Política de Confiança: Libere e Pague',
          body: 'Se o plano vencer durante sua rota e você já for pagante, o L.I.F.O. libera 5 dias de cortesia na confiança direto no app. Ao renovar, o ciclo subsequente será de 25 dias (compensando os 5 dias já utilizados).',
          isBlue: true,
        ),
        _buildAlertCard(
          title: '⚠️ Atenção: Responsabilidade no Trânsito',
          body: 'O L.I.F.O. é um copiloto logístico auxiliar. O condutor é o único responsável pela direção prudente, cumprimento das leis de trânsito (CTB), respeito aos limites de velocidade e zelo pela integridade física da carga.',
          isBlue: false,
        ),
        _buildSectionCard(
          cardBg: cardBg,
          borderColor: borderColor,
          titleColor: titleColor,
          bodyColor: bodyColor,
          num: '04',
          title: 'Propriedade Intelectual e Foro',
          items: const [
            'O software, marca LIFO, algoritmo de empilhamento e interfaces são de propriedade exclusiva de seus desenvolvedores.',
            'Legislação aplicável: República Federativa do Brasil, Marco Civil da Internet e Código de Defesa do Consumidor.',
            'Foro de eleição: Comarca de Florianópolis, Santa Catarina.',
          ],
        ),
        _buildContactFooter(cardBg, borderColor, titleColor, subColor),
      ],
    );
  }

  Widget _buildPrivacyView(
    Color cardBg,
    Color borderColor,
    Color titleColor,
    Color bodyColor,
    Color subColor,
  ) {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      children: [
        _buildHeroCard(
          cardBg: cardBg,
          borderColor: borderColor,
          title: 'Política de Privacidade',
          subtitle: 'Em conformidade com a LGPD (Lei nº 13.709/2018)',
          badgeText: 'Proteção de Dados & Transparência',
          body: 'O L.I.F.O. respeita sua privacidade e tem o compromisso de proteger seus dados pessoais e dados operacionais de carga com os mais rigorosos padrões de segurança da informação.',
        ),
        const SizedBox(height: 14),
        _buildSectionCard(
          cardBg: cardBg,
          borderColor: borderColor,
          titleColor: titleColor,
          bodyColor: bodyColor,
          num: '01',
          title: 'Quais Dados Coletamos',
          items: const [
            'Dados cadastrais: Nome completo, e-mail, telefone, CPF/RG e endereço de faturamento (necessários para validação de segurança e emissão de Pix pelo Asaas).',
            'Dados de autenticação: Credenciais criptografadas via Supabase Auth ou token seguro Google.',
            'Dados operacionais: Listas de entregas, paradas e códigos de rastreio importados para cálculo do baú e roteirização.',
          ],
        ),
        _buildSectionCard(
          cardBg: cardBg,
          borderColor: borderColor,
          titleColor: titleColor,
          bodyColor: bodyColor,
          num: '02',
          title: 'Permissões do Celular e Finalidade',
          items: const [
            'Câmera: Exclusivamente para leitura óptica de códigos de barras nas etiquetas das encomendas. Nenhuma foto ou vídeo pessoal é capturado ou armazenado.',
            'GPS / Localização em Primeiro Plano: Para posicionar o veículo no mapa da rota e recalcular a próxima parada durante a jornada.',
            'Armazenamento Local: Para selecionar e importar planilhas de manifestos (CSV/Excel) e guardar o cache offline de mapas na memória do aparelho.',
          ],
        ),
        _buildSectionCard(
          cardBg: cardBg,
          borderColor: borderColor,
          titleColor: titleColor,
          bodyColor: bodyColor,
          num: '03',
          title: 'Compartilhamento de Dados com Parceiros',
          items: const [
            'Asaas Gestão Financeira: Processamento bancário do Pix, prevenção a fraudes e conformidade financeira.',
            'Supabase: Infraestrutura de banco de dados e autenticação segura com isolamento de registros (RLS).',
            'Nunca vendemos, alugamos ou compartilhamos seus dados com anunciantes ou terceiros não autorizados.',
          ],
        ),
        _buildSectionCard(
          cardBg: cardBg,
          borderColor: borderColor,
          titleColor: titleColor,
          bodyColor: bodyColor,
          num: '04',
          title: 'Seus Direitos sob a LGPD (Art. 18)',
          items: const [
            'Acesso e confirmação da existência de tratamento dos seus dados.',
            'Correção de dados incompletos ou inexatos diretamente em "Minha Conta".',
            'Solicitação de exclusão definitiva de conta e dados pelo e-mail de suporte.',
            'Portabilidade e revogação de consentimento a qualquer momento.',
          ],
        ),
        _buildContactFooter(cardBg, borderColor, titleColor, subColor),
      ],
    );
  }

  Widget _buildHeroCard({
    required Color cardBg,
    required Color borderColor,
    required String title,
    required String subtitle,
    required String badgeText,
    required String body,
  }) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: borderColor),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF2563EB).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              badgeText,
              style: const TextStyle(
                color: Color(0xFF2563EB),
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            title,
            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: const TextStyle(fontSize: 12, color: Color(0xFF64748B)),
          ),
          const SizedBox(height: 12),
          Text(
            body,
            style: const TextStyle(fontSize: 13.5, height: 1.5),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionCard({
    required Color cardBg,
    required Color borderColor,
    required Color titleColor,
    required Color bodyColor,
    required String num,
    required String title,
    required List<String> items,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '$num.',
                style: const TextStyle(
                  color: Color(0xFF2563EB),
                  fontWeight: FontWeight.w800,
                  fontSize: 15,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: titleColor,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          for (final item in items) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('• ', style: TextStyle(color: Color(0xFF2563EB), fontWeight: FontWeight.bold, fontSize: 14)),
                  Expanded(
                    child: Text(
                      item,
                      style: TextStyle(fontSize: 13, height: 1.45, color: bodyColor),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildAlertCard({
    required String title,
    required String body,
    required bool isBlue,
  }) {
    final bg = isBlue ? const Color(0xFFEFF6FF) : const Color(0xFFFFFBEB);
    final border = isBlue ? const Color(0xFFBFDBFE) : const Color(0xFFFDE68A);
    final textColor = isBlue ? const Color(0xFF1E3A8A) : const Color(0xFF78350F);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: textColor,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            body,
            style: TextStyle(fontSize: 12.5, height: 1.45, color: textColor.withValues(alpha: 0.9)),
          ),
        ],
      ),
    );
  }

  Widget _buildContactFooter(
    Color cardBg,
    Color borderColor,
    Color titleColor,
    Color subColor,
  ) {
    return Container(
      margin: const EdgeInsets.only(top: 8, bottom: 20),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        children: [
          const Icon(Icons.shield_outlined, size: 28, color: Color(0xFF2563EB)),
          const SizedBox(height: 8),
          Text(
            'Dúvidas, Privacidade ou Suporte',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: titleColor),
          ),
          const SizedBox(height: 4),
          Text(
            'Nossa equipe está à disposição para atender você:',
            style: TextStyle(fontSize: 12, color: subColor),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          const SelectionArea(
            child: Text(
              'contato@lifo.com.br',
              style: TextStyle(
                color: Color(0xFF2563EB),
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Florianópolis, Santa Catarina · Brasil',
            style: TextStyle(fontSize: 11, color: subColor),
          ),
        ],
      ),
    );
  }
}
