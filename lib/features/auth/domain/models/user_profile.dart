class UserProfile {
  final String id;
  final String name;
  final String email;
  final String plan;
  final DateTime expiresAt;
  final String? avatarUrl;
  final String vehicleType;
  final bool isLoggedIn;
  final bool isGoogleAuth;
  final String? cpf;
  final String? rg;
  final String? phone;
  final String? billingAddress;
  final String? billingCep;
  final String? cityUf;
  final String? fcmToken;

  const UserProfile({
    required this.id,
    required this.name,
    required this.email,
    this.plan = 'Standard',
    required this.expiresAt,
    this.avatarUrl,
    this.vehicleType = 'Van de Carga',
    this.isLoggedIn = false,
    this.isGoogleAuth = false,
    this.cpf,
    this.rg,
    this.phone,
    this.billingAddress,
    this.billingCep,
    this.cityUf,
    this.fcmToken,
  });

  bool get isTrialActive =>
      plan.toLowerCase().contains('trial') && expiresAt.isAfter(DateTime.now());

  bool get isSubscriptionActive => expiresAt.isAfter(DateTime.now());

  UserProfile copyWith({
    String? id,
    String? name,
    String? email,
    String? plan,
    DateTime? expiresAt,
    String? avatarUrl,
    String? vehicleType,
    bool? isLoggedIn,
    bool? isGoogleAuth,
    String? cpf,
    String? rg,
    String? phone,
    String? billingAddress,
    String? billingCep,
    String? cityUf,
    String? fcmToken,
  }) {
    return UserProfile(
      id: id ?? this.id,
      name: name ?? this.name,
      email: email ?? this.email,
      plan: plan ?? this.plan,
      expiresAt: expiresAt ?? this.expiresAt,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      vehicleType: vehicleType ?? this.vehicleType,
      isLoggedIn: isLoggedIn ?? this.isLoggedIn,
      isGoogleAuth: isGoogleAuth ?? this.isGoogleAuth,
      cpf: cpf ?? this.cpf,
      rg: rg ?? this.rg,
      phone: phone ?? this.phone,
      billingAddress: billingAddress ?? this.billingAddress,
      billingCep: billingCep ?? this.billingCep,
      cityUf: cityUf ?? this.cityUf,
      fcmToken: fcmToken ?? this.fcmToken,
    );
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'email': email,
    'plan': plan,
    'expiresAt': expiresAt.toIso8601String(),
    'avatarUrl': avatarUrl,
    'vehicleType': vehicleType,
    'isLoggedIn': isLoggedIn,
    'isGoogleAuth': isGoogleAuth,
    'cpf': cpf,
    'rg': rg,
    'phone': phone,
    'billingAddress': billingAddress,
    'billingCep': billingCep,
    'cityUf': cityUf,
    'fcmToken': fcmToken,
  };

  factory UserProfile.fromMap(Map<String, dynamic> map) => UserProfile(
    id: map['id'] as String? ?? '',
    name: map['name'] as String? ?? '',
    email: map['email'] as String? ?? '',
    plan: map['plan'] as String? ?? 'Standard',
    expiresAt: DateTime.tryParse(map['expiresAt'] as String? ?? '') ??
        DateTime.now().add(const Duration(days: 30)),
    avatarUrl: map['avatarUrl'] as String?,
    vehicleType: map['vehicleType'] as String? ?? 'Van de Carga',
    isLoggedIn: map['isLoggedIn'] as bool? ?? false,
    isGoogleAuth: map['isGoogleAuth'] as bool? ?? false,
    cpf: map['cpf'] as String?,
    rg: map['rg'] as String?,
    phone: map['phone'] as String?,
    billingAddress: map['billingAddress'] as String?,
    billingCep: map['billingCep'] as String?,
    cityUf: map['cityUf'] as String?,
    fcmToken: map['fcmToken'] as String?,
  );
}
