import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/app_colors.dart';
import '../controllers/auth_controller.dart';
import 'login_screen.dart';
import 'subscription_renewal_screen.dart';

class MyAccountScreen extends ConsumerWidget {
  const MyAccountScreen({super.key});

  static Future<void> open(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const MyAccountScreen()),
    );
  }

  String _formatDate(DateTime dt) {
    const weekDays = ['seg.', 'ter.', 'qua.', 'qui.', 'sex.', 'sáb.', 'dom.'];
    const months = ['jan.', 'fev.', 'mar.', 'abr.', 'mai.', 'jun.', 'jul.', 'ago.', 'set.', 'out.', 'nov.', 'dez.'];
    final dayName = weekDays[(dt.weekday - 1).clamp(0, 6)];
    final day = dt.day;
    final month = months[(dt.month - 1).clamp(0, 11)];
    return 'Expira em $dayName $day de $month';
  }

  void _editProfileDialog(BuildContext context, WidgetRef ref) {
    final user = ref.read(authControllerProvider).user;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final nameCtrl = TextEditingController(text: user.name);
    final cpfCtrl = TextEditingController(text: user.cpf ?? '');
    final rgCtrl = TextEditingController(text: user.rg ?? '');
    final phoneCtrl = TextEditingController(text: user.phone ?? '');
    final addressCtrl = TextEditingController(text: user.billingAddress ?? '');
    final cepCtrl = TextEditingController(text: user.billingCep ?? '');

    showDialog(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Editar Dados do Perfil', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildEditField('Nome Completo', nameCtrl, isDark),
              const SizedBox(height: 10),
              _buildEditField('CPF', cpfCtrl, isDark),
              const SizedBox(height: 10),
              _buildEditField('RG', rgCtrl, isDark),
              const SizedBox(height: 10),
              _buildEditField('Telefone / WhatsApp', phoneCtrl, isDark),
              const SizedBox(height: 10),
              _buildEditField('Endereço de Faturamento', addressCtrl, isDark),
              const SizedBox(height: 10),
              _buildEditField('CEP', cepCtrl, isDark),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF2563EB),
              foregroundColor: Colors.white,
            ),
            onPressed: () {
              ref.read(authControllerProvider.notifier).updateProfile(
                name: nameCtrl.text.trim(),
                cpf: cpfCtrl.text.trim(),
                rg: rgCtrl.text.trim(),
                phone: phoneCtrl.text.trim(),
                billingAddress: addressCtrl.text.trim(),
                billingCep: cepCtrl.text.trim(),
              );
              Navigator.pop(dCtx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Dados atualizados com sucesso!'),
                  backgroundColor: Color(0xFF2563EB),
                ),
              );
            },
            child: const Text('Salvar'),
          ),
        ],
      ),
    );
  }

  Widget _buildEditField(String label, TextEditingController ctrl, bool isDark) {
    return TextField(
      controller: ctrl,
      style: TextStyle(color: isDark ? Colors.white : const Color(0xFF0F172A), fontSize: 13),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(fontSize: 12, color: isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B)),
        filled: true,
        fillColor: isDark ? const Color(0xFF0F172A) : const Color(0xFFF1F5F9),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
          'Minha Conta',
          style: TextStyle(color: titleColor, fontSize: 18, fontWeight: FontWeight.w700),
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_outlined, size: 20, color: Color(0xFF2563EB)),
            tooltip: 'Editar Perfil',
            onPressed: () => _editProfileDialog(context, ref),
          ),
        ],
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
                      '${user.plan} (Ativo) • ${_formatDate(user.expiresAt)}',
                      style: const TextStyle(
                        color: Color(0xFF2563EB),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Botão Renovar Assinatura
                  SizedBox(
                    width: double.infinity,
                    height: 42,
                    child: OutlinedButton.icon(
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
                  onTap: () => _editProfileDialog(context, ref),
                  child: const Text(
                    'Editar',
                    style: TextStyle(color: Color(0xFF2563EB), fontSize: 13, fontWeight: FontWeight.w600),
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
                  ),
                  Divider(color: borderColor, height: 1),
                  _buildProfileRow(
                    icon: Icons.badge_outlined,
                    label: 'CPF',
                    value: (user.cpf == null || user.cpf!.isEmpty)
                        ? 'Toque em editar e cadastre seu CPF'
                        : user.cpf!,
                    titleColor: titleColor,
                    subColor: subColor,
                  ),
                  Divider(color: borderColor, height: 1),
                  _buildProfileRow(
                    icon: Icons.assignment_ind_outlined,
                    label: 'RG',
                    value: user.rg ?? '5.482.910-SSP/SC',
                    titleColor: titleColor,
                    subColor: subColor,
                  ),
                  Divider(color: borderColor, height: 1),
                  _buildProfileRow(
                    icon: Icons.phone_outlined,
                    label: 'Telefone / WhatsApp',
                    value: user.phone ?? '(48) 99182-3401',
                    titleColor: titleColor,
                    subColor: subColor,
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
                    value: user.billingAddress ?? 'Rodovia José Carlos Daux, 4633 - Saco Grande',
                    titleColor: titleColor,
                    subColor: subColor,
                  ),
                  Divider(color: borderColor, height: 1),
                  _buildProfileRow(
                    icon: Icons.mail_outline,
                    label: 'CEP',
                    value: user.billingCep ?? '88032-005',
                    titleColor: titleColor,
                    subColor: subColor,
                  ),
                  Divider(color: borderColor, height: 1),
                  _buildProfileRow(
                    icon: Icons.apartment_outlined,
                    label: 'Cidade / UF',
                    value: 'Florianópolis - SC',
                    titleColor: titleColor,
                    subColor: subColor,
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
                    value: 'LIFO Pro (R\$ 19,90 / mês)',
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
                  await ref.read(authControllerProvider.notifier).logout();
                  if (context.mounted) {
                    // Volta para a raiz (tela de login) em vez de ficar parado
                    Navigator.of(context).popUntil((route) => route.isFirst);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Você saiu da sua conta.')),
                    );
                  }
                },
              ),
            ),
            const SizedBox(height: 20),
          ],
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
  }) {
    return Padding(
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
                Text(
                  value,
                  style: TextStyle(fontSize: 13, color: titleColor, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          ?trailingWidget,
        ],
      ),
    );
  }
}
