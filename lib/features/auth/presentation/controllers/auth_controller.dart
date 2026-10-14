import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/network/supabase_service.dart';
import '../../data/services/google_auth_service.dart';
import '../../domain/models/user_profile.dart';

const String _kUserPrefKey = 'lifo_user_profile';

class AuthState {
  final UserProfile user;
  final bool isLoading;
  final String? errorMessage;
  final String? successMessage;

  const AuthState({
    required this.user,
    this.isLoading = false,
    this.errorMessage,
    this.successMessage,
  });

  AuthState copyWith({
    UserProfile? user,
    bool? isLoading,
    String? errorMessage,
    String? successMessage,
  }) {
    return AuthState(
      user: user ?? this.user,
      isLoading: isLoading ?? this.isLoading,
      errorMessage: errorMessage,
      successMessage: successMessage,
    );
  }
}

// Perfil guest padrão — estado inicial enquanto carrega
UserProfile _guestProfile() => UserProfile(
      id: 'guest',
      name: 'Convidado',
      email: 'Faça login para continuar',
      plan: '',
      expiresAt: DateTime(2000),
      isLoggedIn: false,
      isGoogleAuth: false,
    );

class AuthController extends StateNotifier<AuthState> {
  AuthController()
      : super(AuthState(user: _guestProfile())) {
    _loadProfile();
  }

  // ─── CARREGAMENTO INICIAL ────────────────────────────────────────────────

  Future<void> _loadProfile() async {
    try {
      // 1. Prioridade: Supabase Auth — verifica sessão ativa
      final supaUser = SupabaseService.instance.currentUser;
      if (supaUser != null) {
        // Busca perfil remoto no Supabase
        final remoteProfile = await SupabaseService.instance.fetchUserProfile();
        if (remoteProfile != null) {
          await AppDatabase.instance.saveUserProfile(remoteProfile);
          state = state.copyWith(user: remoteProfile);
          return;
        }
      }

      // 2. Fallback: SQLite local
      final dbUser = await AppDatabase.instance.getUserProfile();
      if (dbUser != null && dbUser.isLoggedIn) {
        state = state.copyWith(user: dbUser);
        return;
      }

      // 3. Fallback final: SharedPreferences
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kUserPrefKey);
      if (raw != null) {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        final profile = UserProfile.fromMap(map);
        if (profile.isLoggedIn) {
          state = state.copyWith(user: profile);
          await AppDatabase.instance.saveUserProfile(profile);
        }
      }
    } catch (_) {}
  }

  // ─── PERSISTÊNCIA LOCAL + REMOTA ─────────────────────────────────────────

  Future<void> _saveProfile(UserProfile profile) async {
    try {
      // 1. SQLite local (offline-first)
      await AppDatabase.instance.saveUserProfile(profile);

      // 2. SharedPreferences (espelho rápido para cold start)
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kUserPrefKey, jsonEncode(profile.toMap()));

      // 3. Supabase remoto (se autenticado)
      await SupabaseService.instance.upsertUserProfile(profile);
    } catch (_) {}
  }

  // ─── CADASTRO ────────────────────────────────────────────────────────────

  Future<bool> createAccount({
    required String name,
    required String email,
    required String password,
    String? vehicleType,
    String? cpf,
    String? rg,
    String? phone,
    String? billingAddress,
    String? billingCep,
  }) async {
    state = state.copyWith(isLoading: true, errorMessage: null);
    HapticFeedback.lightImpact();

    try {
      // Registra no Supabase Auth
      final supaUser = await SupabaseService.instance.signUp(
        email: email,
        password: password,
        name: name,
      );

      final userId = supaUser?.id ?? 'usr_${DateTime.now().millisecondsSinceEpoch}';
      final expiresAt = DateTime.now().add(const Duration(days: 30));

      final newUser = UserProfile(
        id: userId,
        name: name.trim(),
        email: email.trim().toLowerCase(),
        plan: 'Standard (Trial 30 Dias)',
        expiresAt: expiresAt,
        isLoggedIn: true,
        isGoogleAuth: false,
        vehicleType: vehicleType ?? 'Van de Carga',
        cpf: cpf,
        rg: rg,
        phone: phone,
        billingAddress: billingAddress,
        billingCep: billingCep,
      );

      await _saveProfile(newUser);

      // Cria assinatura de trial no Supabase
      await SupabaseService.instance.upsertSubscription(
        userId: userId,
        plan: 'Standard (Trial 30 Dias)',
        expiresAt: expiresAt,
        status: 'trial',
        paymentMethod: 'none',
      );

      state = state.copyWith(
        user: newUser,
        isLoading: false,
        successMessage: 'Conta criada! 30 dias de trial liberados.',
      );
      HapticFeedback.mediumImpact();
      return true;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: 'Erro ao criar conta. Verifique sua conexão e tente novamente.',
      );
      return false;
    }
  }

  // ─── LOGIN E-MAIL / SENHA ─────────────────────────────────────────────────

  Future<bool> loginWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    state = state.copyWith(isLoading: true, errorMessage: null);
    HapticFeedback.lightImpact();

    try {
      // Autentica no Supabase
      final supaUser = await SupabaseService.instance.signInWithEmail(
        email: email,
        password: password,
      );

      if (supaUser != null) {
        // Busca dados de perfil e assinatura do Supabase
        final remoteProfile = await SupabaseService.instance.fetchUserProfile();
        final subscription = await SupabaseService.instance.fetchSubscription();

        final plan = subscription?['plan'] as String? ?? 'Standard';
        final expiresAt = DateTime.tryParse(
              subscription?['expires_at'] as String? ?? '',
            ) ??
            DateTime.now().add(const Duration(days: 30));

        final profile = (remoteProfile ?? UserProfile(
          id: supaUser.id,
          name: supaUser.userMetadata?['full_name'] as String? ??
              email.split('@').first,
          email: email.trim().toLowerCase(),
          plan: plan,
          expiresAt: expiresAt,
          isLoggedIn: true,
          isGoogleAuth: false,
        )).copyWith(
          plan: plan,
          expiresAt: expiresAt,
          isLoggedIn: true,
        );

        await _saveProfile(profile);
        state = state.copyWith(
          user: profile,
          isLoading: false,
          successMessage: 'Login realizado com sucesso!',
        );
        HapticFeedback.mediumImpact();
        return true;
      }

      // Fallback offline: login local sem rede
      final dbUser = await AppDatabase.instance.getUserProfile();
      if (dbUser != null && dbUser.email == email.trim().toLowerCase()) {
        final offline = dbUser.copyWith(isLoggedIn: true);
        await AppDatabase.instance.saveUserProfile(offline);
        state = state.copyWith(
          user: offline,
          isLoading: false,
          successMessage: 'Login offline realizado.',
        );
        HapticFeedback.mediumImpact();
        return true;
      }

      state = state.copyWith(
        isLoading: false,
        errorMessage: 'E-mail ou senha incorretos.',
      );
      return false;
    } catch (_) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: 'Falha na conexão. Verifique sua internet.',
      );
      return false;
    }
  }

  // ─── LOGIN GOOGLE ─────────────────────────────────────────────────────────

  /// Executa o fluxo nativo de Google Sign-In:
  /// 1. Abre o seletor de contas do Google
  /// 2. Obtém o idToken
  /// 3. Autentica no Supabase com signInWithIdToken
  /// 4. Salva perfil local + remoto
  Future<bool> loginWithGoogle() async {
    state = state.copyWith(isLoading: true, errorMessage: null);
    HapticFeedback.mediumImpact();

    final result = await GoogleAuthService.instance.signIn();

    if (result.success && result.profile != null) {
      await _saveProfile(result.profile!);
      state = state.copyWith(
        user: result.profile!,
        isLoading: false,
        successMessage: 'Login com Google realizado com sucesso!',
      );
      HapticFeedback.mediumImpact();
      return true;
    } else {
      state = state.copyWith(
        isLoading: false,
        errorMessage: result.errorMessage ?? 'Falha no login com Google.',
      );
      return false;
    }
  }

  // ─── RENOVAR ASSINATURA ──────────────────────────────────────────────────

  Future<void> renewSubscription() async {
    HapticFeedback.selectionClick();
    final newExpiry = state.user.expiresAt.isAfter(DateTime.now())
        ? state.user.expiresAt.add(const Duration(days: 30))
        : DateTime.now().add(const Duration(days: 30));

    final updated = state.user.copyWith(
      expiresAt: newExpiry,
      plan: 'Standard (Ativo)',
    );

    await _saveProfile(updated);

    // Atualiza assinatura no Supabase
    await SupabaseService.instance.upsertSubscription(
      userId: updated.id,
      plan: 'Standard (Ativo)',
      expiresAt: newExpiry,
      status: 'active',
      paymentMethod: 'manual',
    );

    state = state.copyWith(
      user: updated,
      successMessage: 'Assinatura renovada com sucesso!',
    );
  }

  // ─── ATUALIZAR PERFIL ─────────────────────────────────────────────────────

  Future<void> updateProfile({
    String? name,
    String? email,
    String? cpf,
    String? rg,
    String? phone,
    String? billingAddress,
    String? billingCep,
  }) async {
    final updated = state.user.copyWith(
      name: name,
      email: email,
      cpf: cpf,
      rg: rg,
      phone: phone,
      billingAddress: billingAddress,
      billingCep: billingCep,
    );
    await _saveProfile(updated);
    state = state.copyWith(
      user: updated,
      successMessage: 'Perfil atualizado no banco de dados!',
    );
  }

  // ─── LOGOUT ───────────────────────────────────────────────────────────────

  Future<void> logout() async {
    HapticFeedback.lightImpact();

    // Desloga no Supabase
    await SupabaseService.instance.signOut();

    // Limpa sessão local
    final guest = _guestProfile();
    await AppDatabase.instance.saveUserProfile(guest);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kUserPrefKey);

    state = state.copyWith(user: guest);
  }
}

final authControllerProvider =
    StateNotifierProvider<AuthController, AuthState>((ref) {
  return AuthController();
});
