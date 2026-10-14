/// Planos pagos do LIFO Pro. Fonte única dos valores usados na cobrança
/// PIX, na renovação e no webhook (que deriva os dias pelo valor pago).
class SubscriptionPlan {
  final String id;
  final String title;
  final String shortLabel; // selo do takeover ("LIFO PRO • 30 DIAS")
  final String durationLabel; // "/30 dias"
  final double amount;
  final int days;
  final String description; // vai p/ a fatura do Asaas
  final String planName; // vai p/ user_profiles.plan
  final String? badge;

  const SubscriptionPlan({
    required this.id,
    required this.title,
    required this.shortLabel,
    required this.durationLabel,
    required this.amount,
    required this.days,
    required this.description,
    required this.planName,
    this.badge,
  });

  /// "R$ 19,90" / "R$ 200,00"
  String get priceBr =>
      'R\$ ${amount.toStringAsFixed(2).replaceAll('.', ',')}';

  static const monthly = SubscriptionPlan(
    id: 'monthly',
    title: 'Plano Mensal (30 Dias)',
    shortLabel: 'LIFO PRO • 30 DIAS',
    durationLabel: '/30 dias',
    amount: 19.90,
    days: 30,
    description: 'Assinatura LIFO Pro - 30 Dias',
    planName: 'Standard (Ativo)',
    badge: 'RECOMENDADO',
  );

  static const annual = SubscriptionPlan(
    id: 'annual',
    title: 'Plano Anual (365 Dias)',
    shortLabel: 'LIFO PRO • 12 MESES',
    durationLabel: '/12 meses',
    amount: 200.00,
    days: 365,
    description: 'Assinatura LIFO Pro - 365 Dias',
    planName: 'Standard Anual (Ativo)',
    badge: 'MELHOR VALOR',
  );

  static const all = [monthly, annual];

  static SubscriptionPlan byId(String id) =>
      all.firstWhere((p) => p.id == id, orElse: () => monthly);
}
