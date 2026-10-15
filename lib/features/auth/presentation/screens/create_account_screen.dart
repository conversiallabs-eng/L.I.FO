import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/cpf_validator.dart';
import '../controllers/auth_controller.dart';
import '../widgets/google_sign_in_button.dart';
import 'legal_document_screen.dart';

class CreateAccountScreen extends ConsumerStatefulWidget {
  const CreateAccountScreen({super.key});

  static Future<bool?> open(BuildContext context) {
    return Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const CreateAccountScreen()),
    );
  }

  @override
  ConsumerState<CreateAccountScreen> createState() => _CreateAccountScreenState();
}

class _CreateAccountScreenState extends ConsumerState<CreateAccountScreen> {
  final _formKey = GlobalKey<FormState>();

  // 1. Dados Pessoais & Documentos (KYC)
  final _nameCtrl = TextEditingController();
  final _cpfCtrl = TextEditingController();
  final _rgCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();

  // 2. Endereço de Faturamento
  final _cepCtrl = TextEditingController();
  final _streetCtrl = TextEditingController();
  final _numberCtrl = TextEditingController();
  final _neighborhoodCtrl = TextEditingController();
  final _cityCtrl = TextEditingController();
  final _ufCtrl = TextEditingController(text: 'SP');

  // 3. Credenciais e Operação
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _confirmPasswordCtrl = TextEditingController();

  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;
  bool _acceptTerms = true;
  String _selectedVehicle = 'Van de Carga';

  final List<String> _vehicles = [
    'Van de Carga',
    'Fiorino / Utilitário',
    'Moto Entregador',
    'Caminhão Urbano (VUC)',
  ];

  @override
  void dispose() {
    _nameCtrl.dispose();
    _cpfCtrl.dispose();
    _rgCtrl.dispose();
    _phoneCtrl.dispose();
    _cepCtrl.dispose();
    _streetCtrl.dispose();
    _numberCtrl.dispose();
    _neighborhoodCtrl.dispose();
    _cityCtrl.dispose();
    _ufCtrl.dispose();
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _confirmPasswordCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (!_acceptTerms) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Por favor, aceite os termos de uso para continuar.'),
          backgroundColor: AppColors.statusDanger,
        ),
      );
      return;
    }

    final parts = [
      if (_streetCtrl.text.trim().isNotEmpty) _streetCtrl.text.trim(),
      if (_numberCtrl.text.trim().isNotEmpty) 'nº ${_numberCtrl.text.trim()}',
      if (_neighborhoodCtrl.text.trim().isNotEmpty) _neighborhoodCtrl.text.trim(),
      if (_cityCtrl.text.trim().isNotEmpty) '${_cityCtrl.text.trim()} - ${_ufCtrl.text.trim()}',
    ];
    final fullAddress = parts.isNotEmpty ? parts.join(', ') : null;

    final success = await ref.read(authControllerProvider.notifier).createAccount(
          name: _nameCtrl.text,
          email: _emailCtrl.text,
          password: _passwordCtrl.text,
          vehicleType: _selectedVehicle,
          cpf: _cpfCtrl.text.trim(),
          rg: _rgCtrl.text.trim(),
          phone: _phoneCtrl.text.trim(),
          billingAddress: fullAddress,
          billingCep: _cepCtrl.text.trim(),
        );

    if (success && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Cadastro aprovado! 30 dias de trial liberados para ${_nameCtrl.text.trim()}.'),
          backgroundColor: const Color(0xFF2563EB),
          duration: const Duration(seconds: 3),
        ),
      );
      Navigator.of(context).pop(true);
    }
  }

  Future<void> _loginWithGoogle() async {
    final success = await ref.read(authControllerProvider.notifier).loginWithGoogle();
    if (!mounted) return;
    if (success) {
      Navigator.of(context).pop(true);
    } else {
      final error = ref.read(authControllerProvider).errorMessage;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error ?? 'Falha no login com Google.'),
          backgroundColor: const Color(0xFFDC2626),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final authState = ref.watch(authControllerProvider);

    final bg = isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC);
    final cardBg = isDark ? const Color(0xFF1E293B) : Colors.white;
    final titleColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
    final borderColor = isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0);

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: titleColor),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          'Cadastro & Trial 30 Dias',
          style: TextStyle(color: titleColor, fontSize: 17, fontWeight: FontWeight.w700),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Trial Badge Banner
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2563EB).withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFF2563EB).withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.verified_user_outlined, color: Color(0xFF2563EB), size: 28),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Degustação Total de 30 Dias',
                              style: TextStyle(
                                color: Color(0xFF2563EB),
                                fontWeight: FontWeight.w700,
                                fontSize: 14,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Validação única de CPF e Hardware. Após o trial: R\$ 19,90 (Pix) ou R\$ 25,00 (Cartão).',
                              style: TextStyle(color: subColor, fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // ── BLOCO 1: DADOS PESSOAIS & KYC ──────────────────────
                _buildSectionCard(
                  cardBg: cardBg,
                  borderColor: borderColor,
                  titleColor: titleColor,
                  subColor: subColor,
                  isDark: isDark,
                  title: '1. Identificação Pessoal (KYC)',
                  icon: Icons.person_pin_outlined,
                  children: [
                    _buildLabel('Nome Completo', titleColor),
                    TextFormField(
                      controller: _nameCtrl,
                      textCapitalization: TextCapitalization.words,
                      style: TextStyle(color: titleColor, fontSize: 14),
                      decoration: _inputDecoration('Ex: Ronaldo de Almeida', Icons.person_outline, isDark),
                      validator: (v) => (v == null || v.trim().length < 5) ? 'Nome completo obrigatório' : null,
                    ),
                    const SizedBox(height: 14),

                    Row(
                      children: [
                        Expanded(
                          flex: 3,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildLabel('CPF (apenas números)', titleColor),
                              TextFormField(
                                controller: _cpfCtrl,
                                keyboardType: TextInputType.number,
                                style: TextStyle(color: titleColor, fontSize: 14),
                                decoration: _inputDecoration('000.000.000-00', Icons.badge_outlined, isDark),
                                validator: (v) {
                                  if (!CpfValidator.isValid(v)) return 'CPF inválido';
                                  return null;
                                },
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 2,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildLabel('RG', titleColor),
                              TextFormField(
                                controller: _rgCtrl,
                                style: TextStyle(color: titleColor, fontSize: 14),
                                decoration: _inputDecoration('Registro Geral', Icons.credit_card_outlined, isDark),
                                validator: (v) => (v == null || v.trim().isEmpty) ? 'Informe o RG' : null,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),

                    _buildLabel('WhatsApp / Telefone com DDD', titleColor),
                    TextFormField(
                      controller: _phoneCtrl,
                      keyboardType: TextInputType.phone,
                      style: TextStyle(color: titleColor, fontSize: 14),
                      decoration: _inputDecoration('(00) 90000-0000', Icons.phone_android_outlined, isDark),
                      validator: (v) {
                        final clean = (v ?? '').replaceAll(RegExp(r'\D'), '');
                        if (clean.length < 10) return 'Telefone com DDD inválido';
                        return null;
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // ── BLOCO 2: ENDEREÇO DE FATURAMENTO ───────────────────
                _buildSectionCard(
                  cardBg: cardBg,
                  borderColor: borderColor,
                  titleColor: titleColor,
                  subColor: subColor,
                  isDark: isDark,
                  title: '2. Endereço de Faturamento',
                  icon: Icons.location_on_outlined,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          flex: 2,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildLabel('CEP', titleColor),
                              TextFormField(
                                controller: _cepCtrl,
                                keyboardType: TextInputType.number,
                                style: TextStyle(color: titleColor, fontSize: 14),
                                decoration: _inputDecoration('00000-000', Icons.markunread_mailbox_outlined, isDark),
                                validator: (v) => (v == null || v.trim().length < 8) ? 'CEP inválido' : null,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 3,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildLabel('Bairro', titleColor),
                              TextFormField(
                                controller: _neighborhoodCtrl,
                                style: TextStyle(color: titleColor, fontSize: 14),
                                decoration: _inputDecoration('Seu bairro', Icons.holiday_village_outlined, isDark),
                                validator: (v) => (v == null || v.trim().isEmpty) ? 'Obrigatório' : null,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),

                    Row(
                      children: [
                        Expanded(
                          flex: 4,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildLabel('Logradouro', titleColor),
                              TextFormField(
                                controller: _streetCtrl,
                                style: TextStyle(color: titleColor, fontSize: 14),
                                decoration: _inputDecoration('Rua / Avenida', Icons.home_outlined, isDark),
                                validator: (v) => (v == null || v.trim().isEmpty) ? 'Obrigatório' : null,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 2,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildLabel('Número', titleColor),
                              TextFormField(
                                controller: _numberCtrl,
                                keyboardType: TextInputType.number,
                                style: TextStyle(color: titleColor, fontSize: 14),
                                decoration: _inputDecoration('Nº', Icons.pin_outlined, isDark),
                                validator: (v) => (v == null || v.trim().isEmpty) ? 'Nº' : null,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),

                    Row(
                      children: [
                        Expanded(
                          flex: 4,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildLabel('Cidade', titleColor),
                              TextFormField(
                                controller: _cityCtrl,
                                style: TextStyle(color: titleColor, fontSize: 14),
                                decoration: _inputDecoration('Sua cidade', Icons.location_city_outlined, isDark),
                                validator: (v) => (v == null || v.trim().isEmpty) ? 'Obrigatório' : null,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 2,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildLabel('UF', titleColor),
                              TextFormField(
                                controller: _ufCtrl,
                                textCapitalization: TextCapitalization.characters,
                                maxLength: 2,
                                style: TextStyle(color: titleColor, fontSize: 14),
                                decoration: _inputDecoration('UF', Icons.flag_outlined, isDark),
                                validator: (v) => (v == null || v.trim().length != 2) ? 'UF' : null,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // ── BLOCO 3: VEÍCULO & ACESSO ──────────────────────────
                _buildSectionCard(
                  cardBg: cardBg,
                  borderColor: borderColor,
                  titleColor: titleColor,
                  subColor: subColor,
                  isDark: isDark,
                  title: '3. Veículo & Credenciais',
                  icon: Icons.lock_outline,
                  children: [
                    _buildLabel('Veículo de Entrega', titleColor),
                    DropdownButtonFormField<String>(
                      initialValue: _selectedVehicle,
                      dropdownColor: cardBg,
                      style: TextStyle(color: titleColor, fontSize: 14),
                      decoration: _inputDecoration('Selecione', Icons.local_shipping_outlined, isDark),
                      items: _vehicles.map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
                      onChanged: (val) {
                        if (val != null) setState(() => _selectedVehicle = val);
                      },
                    ),
                    const SizedBox(height: 14),

                    _buildLabel('E-mail de Acesso', titleColor),
                    TextFormField(
                      controller: _emailCtrl,
                      keyboardType: TextInputType.emailAddress,
                      style: TextStyle(color: titleColor, fontSize: 14),
                      decoration: _inputDecoration('seuemail@exemplo.com', Icons.email_outlined, isDark),
                      validator: (v) {
                        if (v == null || !v.contains('@') || !v.contains('.')) return 'E-mail inválido';
                        return null;
                      },
                    ),
                    const SizedBox(height: 14),

                    _buildLabel('Senha', titleColor),
                    TextFormField(
                      controller: _passwordCtrl,
                      obscureText: _obscurePassword,
                      style: TextStyle(color: titleColor, fontSize: 14),
                      decoration: _inputDecoration(
                        'Mínimo 6 caracteres',
                        Icons.lock_outline,
                        isDark,
                        suffix: IconButton(
                          icon: Icon(
                            _obscurePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                            size: 18,
                            color: subColor,
                          ),
                          onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                        ),
                      ),
                      validator: (v) => (v == null || v.length < 6) ? 'Mínimo 6 caracteres' : null,
                    ),
                    const SizedBox(height: 14),

                    _buildLabel('Confirmar Senha', titleColor),
                    TextFormField(
                      controller: _confirmPasswordCtrl,
                      obscureText: _obscureConfirmPassword,
                      style: TextStyle(color: titleColor, fontSize: 14),
                      decoration: _inputDecoration(
                        'Repita sua senha',
                        Icons.lock_reset,
                        isDark,
                        suffix: IconButton(
                          icon: Icon(
                            _obscureConfirmPassword ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                            size: 18,
                            color: subColor,
                          ),
                          onPressed: () => setState(() => _obscureConfirmPassword = !_obscureConfirmPassword),
                        ),
                      ),
                      validator: (v) => (v != _passwordCtrl.text) ? 'Senhas não coincidem' : null,
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // Termos
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Checkbox(
                      value: _acceptTerms,
                      activeColor: const Color(0xFF2563EB),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                      onChanged: (val) => setState(() => _acceptTerms = val ?? false),
                    ),
                    Expanded(
                      child: Text.rich(
                        TextSpan(
                          text: 'Concordo com os ',
                          style: TextStyle(color: subColor, fontSize: 12),
                          children: [
                            WidgetSpan(
                              alignment: PlaceholderAlignment.baseline,
                              baseline: TextBaseline.alphabetic,
                              child: GestureDetector(
                                onTap: () => LegalDocumentScreen.openTerms(context),
                                child: const Text(
                                  'Termos de Uso',
                                  style: TextStyle(
                                    color: Color(0xFF2563EB),
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    decoration: TextDecoration.underline,
                                  ),
                                ),
                              ),
                            ),
                            const TextSpan(text: ', a '),
                            WidgetSpan(
                              alignment: PlaceholderAlignment.baseline,
                              baseline: TextBaseline.alphabetic,
                              child: GestureDetector(
                                onTap: () => LegalDocumentScreen.openPrivacy(context),
                                child: const Text(
                                  'Política de Privacidade',
                                  style: TextStyle(
                                    color: Color(0xFF2563EB),
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                    decoration: TextDecoration.underline,
                                  ),
                                ),
                              ),
                            ),
                            const TextSpan(text: ' e ativação do Trial de 30 dias.'),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // Botão Enviar
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton(
                    onPressed: authState.isLoading ? null : _submit,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF2563EB),
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: authState.isLoading
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Text(
                            'Concluir Cadastro & Ativar Trial',
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                          ),
                  ),
                ),
                const SizedBox(height: 20),

                // Divisor OU
                Row(
                  children: [
                    Expanded(child: Divider(color: borderColor)),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      child: Text('OU', style: TextStyle(color: subColor, fontSize: 12, fontWeight: FontWeight.w600)),
                    ),
                    Expanded(child: Divider(color: borderColor)),
                  ],
                ),
                const SizedBox(height: 16),

                // Google
                GoogleSignInButton(
                  onPressed: _loginWithGoogle,
                  text: 'Continuar com o Google',
                  isLoading: authState.isLoading,
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSectionCard({
    required Color cardBg,
    required Color borderColor,
    required Color titleColor,
    required Color subColor,
    required bool isDark,
    required String title,
    required IconData icon,
    required List<Widget> children,
  }) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: const Color(0xFF2563EB)),
              const SizedBox(width: 8),
              Text(
                title,
                style: TextStyle(color: titleColor, fontSize: 14, fontWeight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 14),
          ...children,
        ],
      ),
    );
  }

  Widget _buildLabel(String text, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        text,
        style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }

  InputDecoration _inputDecoration(String hint, IconData icon, bool isDark, {Widget? suffix}) {
    final fillColor = isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9);
    final borderColor = isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0);
    final subColor = isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8);

    return InputDecoration(
      hintText: hint,
      counterText: '',
      hintStyle: TextStyle(color: subColor, fontSize: 13),
      prefixIcon: Icon(icon, size: 18, color: subColor),
      suffixIcon: suffix,
      filled: true,
      fillColor: fillColor,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: borderColor)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: borderColor)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFF2563EB), width: 1.5)),
    );
  }
}
