import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/services/cep_service.dart';
import '../controllers/auth_controller.dart';
import 'login_screen.dart';
import 'subscription_renewal_screen.dart';
import 'legal_document_screen.dart';

class MyAccountScreen extends ConsumerStatefulWidget {
  const MyAccountScreen({super.key});

  static Future<void> open(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const MyAccountScreen()),
    );
  }

  @override
  ConsumerState<MyAccountScreen> createState() => _MyAccountScreenState();
}

class _MyAccountScreenState extends ConsumerState<MyAccountScreen> {
  /// Ordem dos campos (navegação do teclado e salvamento).
  static const _fieldOrder = ['name', 'cpf', 'rg', 'phone', 'address', 'cep', 'cityuf'];

  bool _editing = false;
  bool _saving = false;
  bool _lookingUpCep = false;
  String _lastAutoCep = '';
  Timer? _cepDebounce;
  late final Map<String, TextEditingController> _ctrls;
  late final Map<String, FocusNode> _focus;

  @override
  void initState() {
    super.initState();
    _ctrls = {for (final k in _fieldOrder) k: TextEditingController()};
    _focus = {for (final k in _fieldOrder) k: FocusNode()};
    _syncControllers();
    // Ao completar 8 dígitos no CEP, autocompleta endereço + cidade (BrasilAPI).
    _ctrls['cep']!.addListener(_onCepChanged);
  }

  /// Traz os valores atuais do usuário p/ os campos (ao entrar em edição).
  void _syncControllers() {
    final user = ref.read(authControllerProvider).user;
    _ctrls['name']!.text = user.name;
    _ctrls['cpf']!.text = user.cpf ?? '';
    _ctrls['rg']!.text = user.rg ?? '';
    _ctrls['phone']!.text = user.phone ?? '';
    _ctrls['address']!.text = user.billingAddress ?? '';
    _ctrls['cep']!.text = user.billingCep ?? '';
    _ctrls['cityuf']!.text = user.cityUf ?? '';
  }

  void _onCepChanged() {
    if (!_editing || _saving) return;
    _cepDebounce?.cancel();
    _cepDebounce = Timer(const Duration(milliseconds: 600), () {
      final digits = _ctrls['cep']!.text.replaceAll(RegExp(r'\D'), '');
      if (digits.length == 8 && digits != _lastAutoCep) {
        _lastAutoCep = digits;
        _autofillFromCep(digits);
      }
    });
  }

  /// Preenche endereço e cidade/UF via BrasilAPI sem salvar sozinho.
  Future<void> _autofillFromCep(String digits) async {
    if (_lookingUpCep || !mounted) return;
    setState(() => _lookingUpCep = true);
    try {
      final addr = await CepService.instance.fetchAddress(digits);
      if (!mounted || !_editing || addr == null) return;
      var filled = false;
      if (_ctrls['address']!.text.trim().isEmpty && addr.shortAddress.isNotEmpty) {
        _ctrls['address']!.text = addr.shortAddress;
        filled = true;
      }
      if (addr.cityUf.isNotEmpty && _ctrls['cityuf']!.text.trim().isEmpty) {
        _ctrls['cityuf']!.text = addr.cityUf;
        filled = true;
      }
      if (filled && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Endereço preenchido pelo CEP. Confira e toque em Salvar.'),
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 3),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _lookingUpCep = false);
    }
  }

  @override
  void dispose() {
    _cepDebounce?.cancel();
    _ctrls['cep']?.removeListener(_onCepChanged);
    for (final c in _ctrls.values) {
      c.dispose();
    }
    for (final f in _focus.values) {
      f.dispose();
    }
    super.dispose();
  }

  String _formatDate(DateTime dt) {
    final day = dt.day.toString().padLeft(2, '0');
    final month = dt.month.toString().padLeft(2, '0');
    final year = dt.year.toString();
    return 'Válido até $day/$month/$year';
  }

  /// Entra em modo de edição; [focusField] já abre o teclado nesse campo.
  void _enterEdit({String? focusField}) {
    if (_saving) return;
    _syncControllers();
    setState(() => _editing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final key = focusField ?? 'name';
      _focus[key]?.requestFocus();
    });
  }

  void _cancelEdit() {
    if (_saving) return;
    FocusScope.of(context).unfocus();
    setState(() => _editing = false);
  }

  /// Salva (botão Editar/Salvar ou Enter do teclado).
  Future<void> _saveEdits() async {
    if (_saving) return;
    setState(() => _saving = true);
    FocusScope.of(context).unfocus();

    // Última chance do autocomplete: CEP válido + endereço/cidade vazios.
    final cepDigits = _ctrls['cep']!.text.replaceAll(RegExp(r'\D'), '');
    if (cepDigits.length == 8 &&
        (_ctrls['address']!.text.trim().isEmpty || _ctrls['cityuf']!.text.trim().isEmpty)) {
      final addr = await CepService.instance.fetchAddress(cepDigits);
      if (addr != null) {
        if (_ctrls['address']!.text.trim().isEmpty && addr.shortAddress.isNotEmpty) {
          _ctrls['address']!.text = addr.shortAddress;
        }
        if (_ctrls['cityuf']!.text.trim().isEmpty && addr.cityUf.isNotEmpty) {
          _ctrls['cityuf']!.text = addr.cityUf;
        }
      }
    }

    final ok = await ref.read(authControllerProvider.notifier).updateProfile(
          name: _ctrls['name']!.text.trim(),
          cpf: _ctrls['cpf']!.text.trim(),
          rg: _ctrls['rg']!.text.trim(),
          phone: _ctrls['phone']!.text.trim(),
          billingAddress: _ctrls['address']!.text.trim(),
          billingCep: _ctrls['cep']!.text.trim(),
          cityUf: _ctrls['cityuf']!.text.trim(),
        );

    if (!mounted) return;
    setState(() {
      _saving = false;
      if (ok) _editing = false;
    });
    final successMsg = ref.read(authControllerProvider).successMessage;
    final err = ref.read(authControllerProvider).errorMessage;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok ? (successMsg ?? 'Dados atualizados com sucesso!') : (err ?? 'O servidor recusou os dados.'),
        ),
        backgroundColor: ok ? const Color(0xFF059669) : const Color(0xFFDC2626),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: ok ? 4 : 6),
      ),
    );
  }

  /// Enter no campo: avança p/ o próximo ou salva no último.
  void _onFieldSubmitted(String key) {
    final idx = _fieldOrder.indexOf(key);
    if (idx >= 0 && idx < _fieldOrder.length - 1) {
      _focus[_fieldOrder[idx + 1]]?.requestFocus();
    } else {
      _saveEdits();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final authState = ref.watch(authControllerProvider);
    final user = authState.user;

    // Se NÃO estiver logado: exibe a tela de login como solicitado
    if (!user.isLoggedIn) {
      return const LoginScreen();
    }

    final bg = isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC);
    final cardBg = isDark ? const Color(0xFF1E293B) : Colors.white;
    final titleColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
    final borderColor = isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0);

    // Voltar no meio da edição cancela a edição em vez de sair da tela.
    return PopScope(
      canPop: !_editing && !_saving,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && mounted) _cancelEdit();
      },
      child: Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: titleColor),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          'Minha Conta',
          style: TextStyle(color: titleColor, fontSize: 18, fontWeight: FontWeight.w700),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          children: [
            // ── CARD DO PERFIL / ASSINATURA ──
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: cardBg,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: borderColor),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: isDark ? 0.2 : 0.04),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                children: [
                  // Avatar circular com iniciais
                  Container(
                    width: 76,
                    height: 76,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const LinearGradient(
                        colors: [Color(0xFF34D399), Color(0xFF059669), Color(0xFF0284C7)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF059669).withValues(alpha: 0.3),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Center(
                      child: Text(
                        user.name.isNotEmpty
                            ? user.name.split(' ').map((e) => e.isNotEmpty ? e[0] : '').take(2).join().toUpperCase()
                            : 'CL',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 26,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.0,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    user.name,
                    style: TextStyle(
                      color: titleColor,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    user.email,
                    style: TextStyle(
                      color: subColor,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2563EB).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      '${user.plan} • ${_formatDate(user.expiresAt)}',
                      style: const TextStyle(
                        color: Color(0xFF2563EB),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                                // Botão Ativar Trial ou Renovar Assinatura
                  SizedBox(
                    width: double.infinity,
                    height: 42,
                    child: user.plan.toLowerCase().contains('pendente')
                        ? ElevatedButton.icon(
                            icon: const Icon(Icons.verified_user_outlined, size: 20, color: Colors.white),
                            label: const Text(
                              'Completar Dados e Liberar 30 Dias Grátis',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF2563EB),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                            onPressed: () {
                              _enterEdit(focusField: 'cpf');
                            },
                          )
                        : OutlinedButton.icon(
                            icon: const Icon(Icons.bolt, size: 20, color: Color(0xFF2563EB)),
                            label: const Text(
                              'Renovar Assinatura',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF2563EB),
                              ),
                            ),
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(color: Color(0xFF2563EB), width: 1.4),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              backgroundColor: const Color(0xFF2563EB).withValues(alpha: 0.05),
                            ),
                            onPressed: () {
                              SubscriptionRenewalScreen.open(context);
                            },
                          ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // ── DADOS PESSOAIS & DOCUMENTOS (CPF, RG, TELEFONE) ──
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Dados Pessoais & Documentos',
                  style: TextStyle(color: titleColor, fontSize: 14, fontWeight: FontWeight.w700),
                ),
                InkWell(
                  onTap: _saving ? null : () => _editing ? _saveEdits() : _enterEdit(),
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: _saving
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(
                            _editing ? 'Salvar' : 'Editar',
                            style: TextStyle(
                              color: _editing
                                  ? const Color(0xFF059669)
                                  : const Color(0xFF2563EB),
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),

            Container(
              decoration: BoxDecoration(
                color: cardBg,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: borderColor),
              ),
              child: Column(
                children: [
                  _buildProfileRow(
                    icon: Icons.person_outline,
                    label: 'Nome Completo',
                    value: user.name,
                    titleColor: titleColor,
                    subColor: subColor,
                    fieldKey: 'name',
                    capitalization: TextCapitalization.words,
                    hint: 'Seu nome completo',
                  ),
                  Divider(color: borderColor, height: 1),
                  _buildProfileRow(
                    icon: Icons.badge_outlined,
                    label: 'CPF',
                    value: (user.cpf == null || user.cpf!.isEmpty)
                        ? 'Toque na linha e cadastre seu CPF'
                        : user.cpf!,
                    titleColor: titleColor,
                    subColor: subColor,
                    fieldKey: 'cpf',
                    keyboard: TextInputType.number,
                    hint: '000.000.000-00',
                  ),
                  Divider(color: borderColor, height: 1),
                  _buildProfileRow(
                    icon: Icons.assignment_ind_outlined,
                    label: 'RG',
                    value: (user.rg == null || user.rg!.isEmpty)
                        ? 'Toque na linha e cadastre seu RG'
                        : user.rg!,
                    titleColor: titleColor,
                    subColor: subColor,
                    fieldKey: 'rg',
                    hint: 'Seu RG',
                  ),
                  Divider(color: borderColor, height: 1),
                  _buildProfileRow(
                    icon: Icons.phone_outlined,
                    label: 'Telefone / WhatsApp',
                    value: (user.phone == null || user.phone!.isEmpty)
                        ? 'Toque na linha e cadastre seu telefone'
                        : user.phone!,
                    titleColor: titleColor,
                    subColor: subColor,
                    fieldKey: 'phone',
                    keyboard: TextInputType.phone,
                    hint: '(00) 90000-0000',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // ── ENDEREÇO DE FATURAMENTO ──
            Text(
              'Endereço de Faturamento',
              style: TextStyle(color: titleColor, fontSize: 14, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),

            Container(
              decoration: BoxDecoration(
                color: cardBg,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: borderColor),
              ),
              child: Column(
                children: [
                  _buildProfileRow(
                    icon: Icons.location_on_outlined,
                    label: 'Endereço',
                    value: (user.billingAddress == null || user.billingAddress!.isEmpty)
                        ? 'Toque na linha e cadastre seu endereço'
                        : user.billingAddress!,
                    titleColor: titleColor,
                    subColor: subColor,
                    fieldKey: 'address',
                    capitalization: TextCapitalization.sentences,
                    hint: 'Rua, número, bairro',
                  ),
                  Divider(color: borderColor, height: 1),
                  _buildProfileRow(
                    icon: Icons.mail_outline,
                    label: 'CEP',
                    value: (user.billingCep == null || user.billingCep!.isEmpty)
                        ? 'Toque na linha e cadastre seu CEP'
                        : user.billingCep!,
                    titleColor: titleColor,
                    subColor: subColor,
                    fieldKey: 'cep',
                    keyboard: TextInputType.number,
                    hint: '00000-000',
                  ),
                  Divider(color: borderColor, height: 1),
                  _buildProfileRow(
                    icon: Icons.apartment_outlined,
                    label: 'Cidade / UF',
                    value: (user.cityUf == null || user.cityUf!.isEmpty)
                        ? 'Preenchido pelo CEP ou toque na linha'
                        : user.cityUf!,
                    titleColor: titleColor,
                    subColor: subColor,
                    fieldKey: 'cityuf',
                    capitalization: TextCapitalization.words,
                    hint: 'Cidade - UF',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // ── ASSINATURA & PLANO ──
            Text(
              'Assinatura & Plano',
              style: TextStyle(color: titleColor, fontSize: 14, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),

            Container(
              decoration: BoxDecoration(
                color: cardBg,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: borderColor),
              ),
              child: Column(
                children: [
                  _buildProfileRow(
                    icon: Icons.credit_card_outlined,
                    label: 'Plano Ativo',
                    value: 'LIFO Pro • ${user.plan}',
                    titleColor: titleColor,
                    subColor: subColor,
                  ),
                  Divider(color: borderColor, height: 1),
                  _buildProfileRow(
                    icon: Icons.check_circle_outline,
                    label: 'Status da Conta',
                    value: 'Regular / Acesso Ilimitado',
                    titleColor: titleColor,
                    subColor: subColor,
                    trailingWidget: const Icon(Icons.verified, color: AppColors.statusSuccess, size: 18),
                  ),
                  Divider(color: borderColor, height: 1),
                  _buildProfileRow(
                    icon: Icons.calendar_today_outlined,
                    label: 'Renovação',
                    value: _formatDate(user.expiresAt),
                    titleColor: titleColor,
                    subColor: subColor,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // ── INFORMAÇÕES LEGAIS & TERMOS ──
            Text(
              'Informações Legais & Termos',
              style: TextStyle(color: titleColor, fontSize: 14, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),

            Container(
              decoration: BoxDecoration(
                color: cardBg,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: borderColor),
              ),
              child: Column(
                children: [
                  InkWell(
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
                    onTap: () => LegalDocumentScreen.openTerms(context),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
                      child: Row(
                        children: [
                          const Icon(Icons.description_outlined, size: 20, color: Color(0xFF2563EB)),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Text(
                              'Termos de Uso do Serviço',
                              style: TextStyle(fontSize: 13, color: titleColor, fontWeight: FontWeight.w600),
                            ),
                          ),
                          Icon(Icons.chevron_right, size: 20, color: subColor),
                        ],
                      ),
                    ),
                  ),
                  Divider(color: borderColor, height: 1),
                  InkWell(
                    onTap: () => LegalDocumentScreen.openPrivacy(context),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
                      child: Row(
                        children: [
                          const Icon(Icons.privacy_tip_outlined, size: 20, color: Color(0xFF2563EB)),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Text(
                              'Política de Privacidade (LGPD)',
                              style: TextStyle(fontSize: 13, color: titleColor, fontWeight: FontWeight.w600),
                            ),
                          ),
                          Icon(Icons.chevron_right, size: 20, color: subColor),
                        ],
                      ),
                    ),
                  ),
                  Divider(color: borderColor, height: 1),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Row(
                      children: [
                        const Icon(Icons.info_outline, size: 20, color: Color(0xFF2563EB)),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Versão do Aplicativo',
                                style: TextStyle(fontSize: 11, color: subColor, fontWeight: FontWeight.w500),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                'L.I.F.O. v1.0.0 (Build 1)',
                                style: TextStyle(fontSize: 13, color: titleColor, fontWeight: FontWeight.w600),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 28),

            // ── BOTÃO SAIR DA CONTA ──
            SizedBox(
              height: 48,
              child: OutlinedButton.icon(
                icon: const Icon(Icons.logout, size: 18, color: AppColors.statusDanger),
                label: const Text(
                  'Sair da Conta',
                  style: TextStyle(color: AppColors.statusDanger, fontWeight: FontWeight.w700, fontSize: 14),
                ),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: AppColors.statusDanger.withValues(alpha: 0.5)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: () async {
                  final confirm = await showDialog<bool>(
                    context: context,
                    barrierDismissible: true,
                    builder: (dCtx) => AlertDialog(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                      title: const Text(
                        'Sair da conta?',
                        style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                      ),
                      content: const Text(
                        'Você vai para a tela de login e a sessão atual é encerrada em todos os serviços.',
                        style: TextStyle(fontSize: 13),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(dCtx, false),
                          child: const Text('Cancelar'),
                        ),
                        FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: AppColors.statusDanger,
                          ),
                          onPressed: () => Navigator.pop(dCtx, true),
                          child: const Text('Sair'),
                        ),
                      ],
                    ),
                  );
                  if (confirm != true) return;
                  if (context.mounted) {
                    showDialog(
                      context: context,
                      barrierDismissible: false,
                      builder: (_) => const Center(
                        child: CircularProgressIndicator(),
                      ),
                    );
                  }
                  await ref.read(authControllerProvider.notifier).logout();
                  if (context.mounted) {
                    // Zera a pilha: nenhuma rota do app logado sobrevive.
                    LoginScreen.open(context);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Você saiu da sua conta.'),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  }
                },
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
      ),
    );
  }

  Widget _buildProfileRow({
    required IconData icon,
    required String label,
    required String value,
    required Color titleColor,
    required Color subColor,
    Widget? trailingWidget,
    // Linha editável: toque abre edição inline, Enter salva.
    String? fieldKey,
    TextInputType keyboard = TextInputType.text,
    TextCapitalization capitalization = TextCapitalization.none,
    String? hint,
  }) {
    final key = fieldKey;
    final isFieldEditing = _editing && key != null;

    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(icon, size: 20, color: const Color(0xFF2563EB)),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(fontSize: 11, color: subColor, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 2),
                if (isFieldEditing)
                  TextField(
                    controller: _ctrls[key]!,
                    focusNode: _focus[key]!,
                    keyboardType: keyboard,
                    textCapitalization: capitalization,
                    textInputAction: key == _fieldOrder.last
                        ? TextInputAction.done
                        : TextInputAction.next,
                    onSubmitted: (_) => _onFieldSubmitted(key),
                    style: TextStyle(
                      fontSize: 13,
                      color: titleColor,
                      fontWeight: FontWeight.w600,
                    ),
                    decoration: InputDecoration(
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                      border: InputBorder.none,
                      hintText: hint ?? value,
                      hintStyle: TextStyle(
                        fontSize: 13,
                        color: subColor,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  )
                else
                  Text(
                    value,
                    style: TextStyle(fontSize: 13, color: titleColor, fontWeight: FontWeight.w600),
                  ),
              ],
            ),
          ),
          if (key != null && !_editing)
            Icon(Icons.edit_outlined, size: 14, color: subColor),
          if (key == 'cep' && _lookingUpCep && _editing)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ?trailingWidget,
        ],
      ),
    );

    // Fora da edição, a linha inteira é o botão de editar aquele campo.
    if (key != null && !_editing) {
      return InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _enterEdit(focusField: key),
        child: content,
      );
    }
    return content;
  }
}
