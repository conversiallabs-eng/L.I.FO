import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/cpf_validator.dart';
import '../controllers/auth_controller.dart';
import 'legal_document_screen.dart';
import 'subscription_renewal_screen.dart';

/// Tela obrigatória de onboarding/KYC para contas Google ou cadastros
/// sem CPF. Impede o acesso ao app e a ativação de Trial até que um CPF
/// válido e não utilizado seja verificado.
class CompleteRegistrationScreen extends ConsumerStatefulWidget {
  const CompleteRegistrationScreen({super.key});

  @override
  ConsumerState<CompleteRegistrationScreen> createState() =>
      _CompleteRegistrationScreenState();
}

class _CompleteRegistrationScreenState
    extends ConsumerState<CompleteRegistrationScreen> {
  final _formKey = GlobalKey<FormState>();
  final _cpfCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  String _selectedVehicle = 'Van de Carga';
  bool _acceptTerms = true;

  final List<String> _vehicles = [
    'Van de Carga',
    'Fiorino / Utilitário',
    'Moto de Entrega',
    'Carro de Passeio',
    'Caminhão VUC / Médio',
  ];

  @override
  void dispose() {
    _cpfCtrl.dispose();
    _phoneCtrl.dispose();
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

    final success = await ref
        .read(authControllerProvider.notifier)
        .completeKycAndActivateTrial(
          cpf: _cpfCtrl.text.trim(),
          phone: _phoneCtrl.text.trim(),
          vehicleType: _selectedVehicle,
        );

    if (!mounted) return;

    if (!success) {
      final err = ref.read(authControllerProvider).errorMessage ??
          'Não foi possível ativar o período de teste com este CPF.';

      final isTrialUsed = err.toLowerCase().contains('já foi utilizado') ||
          err.toLowerCase().contains('já utilizado');

      if (isTrialUsed) {
        await showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.workspace_premium, color: Color(0xFF2563EB)),
                SizedBox(width: 8),
                Text('Teste Já Utilizado', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ],
            ),
            content: Text(
              '$err\n\nPara continuar utilizando o L.I.F.O sem limites, escolha seu plano de assinatura.',
              style: const TextStyle(fontSize: 14),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Ver Planos e Assinar', style: TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF2563EB))),
              ),
            ],
          ),
        );
        if (mounted) {
          SubscriptionRenewalScreen.openLocked(context);
        }
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(err),
          backgroundColor: AppColors.statusDanger,
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  InputDecoration _inputDecoration(String hint, IconData icon, bool isDark) {
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(
        color: isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8),
        fontSize: 13,
      ),
      prefixIcon: Icon(
        icon,
        size: 18,
        color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B),
      ),
      filled: true,
      fillColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(
          color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
        ),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(
          color: isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0),
        ),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Color(0xFF2563EB), width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Color(0xFFEF4444)),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Color(0xFFEF4444), width: 1.5),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final authState = ref.watch(authControllerProvider);
    final user = authState.user;

    final bg = isDark ? const Color(0xFF0F172A) : const Color(0xFFF8FAFC);
    final cardBg = isDark ? const Color(0xFF1E293B) : Colors.white;
    final borderColor = isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0);
    final titleColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final subColor = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

    return Scaffold(
      backgroundColor: bg,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Cabeçalho / Identidade
                    Center(
                      child: Container(
                        width: 64,
                        height: 64,
                        decoration: BoxDecoration(
                          color: const Color(0xFF2563EB).withValues(alpha: 0.12),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: const Color(0xFF2563EB).withValues(alpha: 0.25),
                            width: 1.5,
                          ),
                        ),
                        child: const Icon(
                          Icons.verified_user_outlined,
                          color: Color(0xFF2563EB),
                          size: 32,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Ative seus 30 Dias Grátis',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                        color: titleColor,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Olá, ${user.name.split(' ').first}! Para ativar sua licença e proteger sua conta de entregas, confirme seus dados cadastrais.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 13,
                        color: subColor,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 20),

                    // Card de Identificação Google Vinculada
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      decoration: BoxDecoration(
                        color: isDark ? const Color(0xFF131D30) : const Color(0xFFEFF6FF),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: const Color(0xFF2563EB).withValues(alpha: 0.2),
                        ),
                      ),
                      child: Row(
                        children: [
                          if (user.avatarUrl != null && user.avatarUrl!.isNotEmpty)
                            CircleAvatar(
                              radius: 18,
                              backgroundImage: NetworkImage(user.avatarUrl!),
                            )
                          else
                            const CircleAvatar(
                              radius: 18,
                              backgroundColor: Color(0xFF2563EB),
                              child: Icon(Icons.person, color: Colors.white, size: 20),
                            ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  user.name,
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: titleColor,
                                  ),
                                ),
                                Text(
                                  user.email,
                                  style: TextStyle(fontSize: 12, color: subColor),
                                ),
                              ],
                            ),
                          ),
                          const Icon(
                            Icons.check_circle,
                            color: Color(0xFF10B981),
                            size: 18,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Card do Formulário (CPF + Telefone + Veículo)
                    Container(
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        color: cardBg,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: borderColor),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.04),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // CPF
                          Row(
                            children: [
                              Text(
                                'CPF (apenas números)',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: titleColor,
                                ),
                              ),
                              const SizedBox(width: 4),
                              const Text(
                                '*',
                                style: TextStyle(
                                  color: Color(0xFFEF4444),
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          TextFormField(
                            controller: _cpfCtrl,
                            keyboardType: TextInputType.number,
                            maxLength: 14,
                            style: TextStyle(color: titleColor, fontSize: 14),
                            decoration: _inputDecoration(
                              '000.000.000-00',
                              Icons.badge_outlined,
                              isDark,
                            ).copyWith(counterText: ''),
                            validator: (v) {
                              if (v == null || v.trim().isEmpty) {
                                return 'Informe seu CPF para validação única';
                              }
                              if (!CpfValidator.isValid(v)) {
                                return 'CPF inválido. Verifique os dígitos.';
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: 14),

                          // Telefone / WhatsApp
                          Row(
                            children: [
                              Text(
                                'Telefone / WhatsApp',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: titleColor,
                                ),
                              ),
                              const SizedBox(width: 4),
                              const Text(
                                '*',
                                style: TextStyle(
                                  color: Color(0xFFEF4444),
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          TextFormField(
                            controller: _phoneCtrl,
                            keyboardType: TextInputType.phone,
                            style: TextStyle(color: titleColor, fontSize: 14),
                            decoration: _inputDecoration(
                              '(11) 99999-9999',
                              Icons.phone_outlined,
                              isDark,
                            ),
                            validator: (v) {
                              final d = (v ?? '').replaceAll(RegExp(r'\D'), '');
                              if (d.length < 10 || d.length > 11) {
                                return 'Telefone com DDD obrigatório';
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: 14),

                          // Tipo de Veículo
                          Text(
                            'Veículo de Operação',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: titleColor,
                            ),
                          ),
                          const SizedBox(height: 6),
                          DropdownButtonFormField<String>(
                            initialValue: _selectedVehicle,
                            dropdownColor: cardBg,
                            style: TextStyle(color: titleColor, fontSize: 14),
                            decoration: _inputDecoration(
                              'Selecione seu veículo',
                              Icons.local_shipping_outlined,
                              isDark,
                            ),
                            items: _vehicles
                                .map(
                                  (v) => DropdownMenuItem(
                                    value: v,
                                    child: Text(v),
                                  ),
                                )
                                .toList(),
                            onChanged: (val) {
                              if (val != null) setState(() => _selectedVehicle = val);
                            },
                          ),
                          const SizedBox(height: 16),

                          // Alerta de Auditoria Anti-Fraude
                          Container(
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: isDark
                                  ? const Color(0xFF0F172A)
                                  : const Color(0xFFF1F5F9),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.shield_outlined,
                                  size: 16,
                                  color: Color(0xFF2563EB),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Auditoria única por CPF e Hardware. O período de teste de 30 dias é concedido apenas 1 única vez por CPF (vitalício).',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: subColor,
                                      height: 1.3,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Termos de Uso
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Checkbox(
                          value: _acceptTerms,
                          activeColor: const Color(0xFF2563EB),
                          onChanged: (v) => setState(() => _acceptTerms = v ?? false),
                        ),
                        Expanded(
                          child: Wrap(
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(
                                'Li e concordo com os ',
                                style: TextStyle(fontSize: 12, color: subColor),
                              ),
                              GestureDetector(
                                onTap: () => LegalDocumentScreen.openTerms(context),
                                child: const Text(
                                  'Termos de Uso',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Color(0xFF2563EB),
                                    fontWeight: FontWeight.w600,
                                    decoration: TextDecoration.underline,
                                  ),
                                ),
                              ),
                              Text(
                                ' e ',
                                style: TextStyle(fontSize: 12, color: subColor),
                              ),
                              GestureDetector(
                                onTap: () => LegalDocumentScreen.openPrivacy(context),
                                child: const Text(
                                  'Privacidade',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Color(0xFF2563EB),
                                    fontWeight: FontWeight.w600,
                                    decoration: TextDecoration.underline,
                                  ),
                                ),
                              ),
                              Text(
                                '.',
                                style: TextStyle(fontSize: 12, color: subColor),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    // Botão Principal: Ativar 30 Dias Grátis
                    SizedBox(
                      height: 50,
                      child: ElevatedButton(
                        onPressed: authState.isLoading ? null : _submit,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF2563EB),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                          elevation: 0,
                        ),
                        child: authState.isLoading
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.2,
                                  color: Colors.white,
                                ),
                              )
                            : const Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.bolt, size: 20),
                                  SizedBox(width: 8),
                                  Text(
                                    'Ativar 30 Dias Grátis',
                                    style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.bold,
                                      letterSpacing: 0.2,
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    ),
                    const SizedBox(height: 10),

                    // Botão direto para Assinatura (para quem já usou o teste ou quer assinar)
                    OutlinedButton.icon(
                      onPressed: authState.isLoading
                          ? null
                          : () => SubscriptionRenewalScreen.open(context),
                      icon: const Icon(Icons.workspace_premium_outlined, size: 18, color: Color(0xFF2563EB)),
                      label: const Text(
                        'Já utilizou o teste grátis? Assinar L.I.F.O PRO',
                        style: TextStyle(
                          color: Color(0xFF2563EB),
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(
                          color: isDark ? const Color(0xFF334155) : const Color(0xFFCBD5E1),
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Opção de Sair / Trocar de Conta
                    TextButton(
                      onPressed: authState.isLoading
                          ? null
                          : () async {
                              await ref
                                  .read(authControllerProvider.notifier)
                                  .logout();
                            },
                      child: Text(
                        'Entrou na conta errada? Sair e trocar de conta',
                        style: TextStyle(
                          fontSize: 12,
                          color: subColor,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
