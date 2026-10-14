import 'dart:convert';
import 'package:flutter/foundation.dart';
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
  final bool isBooting;
  final String? errorMessage;
  final String? successMessage;

  const AuthState({
    required this.user,
    this.isLoading = false,
    this.isBooting = false,
    this.errorMessage,
    this.successMessage,
  });

  AuthState copyWith({
    UserProfile? user,
    bool? isLoading,
    bool? isBooting,
    String? errorMessage,
    String? successMessage,
  }) {
    return AuthState(
      user: user ?? this.user,
      isLoading: isLoading ?? this.isLoading,
      isBooting: isBooting ?? this.isBooting,
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
      : super(AuthState(user: _guestProfile(), isBooting: true)) {
    _loadProfile();
  }

  // ─── CARREGAMENTO INICIAL ────────────────────────────────────────────────
  // Única fonte da verdade: Supabase. Sem fallback local (SQLite/prefs)
  // para nunca ressuscitar login apagado no servidor.

  Future<void> _loadProfile() async {
    try {
      // 0. Garante o Supabase iniciado (se o boot foi sem rede, tenta de novo).
      if (!SupabaseService.instance.isInitialized) {
        debugPrint('AuthBoot: Supabase não iniciou no main, retentando…');
        await SupabaseService.instance.initialize();
      }

      // 1. Aguarda a sessão persistida voltar (storage local é async).
      var supaUser = SupabaseService.instance.currentUser;
      for (var i = 0;
          supaUser == null && i < 25;
          i++) {
        await Future.delayed(const Duration(milliseconds: 200));
        supaUser = SupabaseService.instance.currentUser;
      }
      if (supaUser == null) {
        // 2. Nada restaurado: tenta renovar com o refresh token salvo
        // (access token expirado entre um boot e outro).
        debugPrint('AuthBoot: sem sessão restaurada, tentando refresh…');
        supaUser = await SupabaseService.instance.refreshSession();
      }
      if (supaUser == null) {
        debugPrint('AuthBoot: sem sessão (login necessário).');
        state = state.copyWith(user: _guestProfile(), isBooting: false);
        return;
      }

      // 3. Sessão OK: busca o perfil com retentativas (rede no boot falha
      // direto — era isso que derrubava o login "permanente").
      debugPrint('AuthBoot: sessão de ${supaUser.email}, buscando perfil…');
      for (var attempt = 1; attempt <= 4; attempt++) {
        final remoteProfile =
            await SupabaseService.instance.fetchUserProfile();
        if (remoteProfile != null) {
          debugPrint('AuthBoot: perfil restaurado.');
          state = state.copyWith(user: remoteProfile, isBooting: false);
          return;
        }
        // Só espera e tenta de novo se a sessão continua válida.
        if (SupabaseService.instance.currentUser == null) break;
        debugPrint('AuthBoot: perfil tentativa $attempt falhou, retentando…');
        await Future.delayed(const Duration(seconds: 2));
      }
      debugPrint('AuthBoot: sessão válida mas sem perfil no servidor.');
    } catch (e) {
      debugPrint('AuthBoot: erro $e');
    }
    state = state.copyWith(user: _guestProfile(), isBooting: false);
  }

  // ─── PERSISTÊNCIA ────────────────────────────────────────────────────────
  // Espelho local mantido só como cache; leitura oficial é sempre Supabase.

  /// Salva local (sempre) + Supabase (quando dá).
  /// Retorna null se o servidor aceitou, ou a mensagem de erro real.
  /// O erro do servidor NUNCA mais é engolido em silêncio.
  Future<String?> _saveProfile(UserProfile profile) async {
    try {
      // 1. SQLite local (offline-first)
      await AppDatabase.instance.saveUserProfile(profile);
    } catch (_) {}
    try {
      // 2. SharedPreferences (espelho rápido para cold start)
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kUserPrefKey, jsonEncode(profile.toMap()));
    } catch (_) {}

    // 3. Supabase remoto (se autenticado) — erro retorna p/ o chamador exibir.
    try {
      return await SupabaseService.instance.upsertUserProfile(profile);
    } catch (e) {
      return e.toString().replaceFirst('Exception: ', '');
    }
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

      // Sem conta no Supabase, sem cadastro (única fonte da verdade).
      if (supaUser == null) {
        state = state.copyWith(
          isLoading: false,
          errorMessage: 'Não foi possível criar a conta no servidor.',
        );
        return false;
      }

      final userId = supaUser.id;
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

        final plan = SupabaseService.planDisplayName(subscription);
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

      // Sem login no Supabase, sem entrada (única fonte da verdade).
      // Mensagem cita os dois casos: conta inexistente ou senha errada.
      state = state.copyWith(
        isLoading: false,
        errorMessage:
            'Conta não encontrada ou senha incorreta. Confira os dados ou toque em Cadastre-se.',
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

  /// Renova a assinatura por [days] (30 mensal · 365 anual).
  Future<void> renewSubscription({
    int days = 30,
    String plan = 'Standard (Ativo)',
  }) async {
    HapticFeedback.selectionClick();
    final newExpiry = state.user.expiresAt.isAfter(DateTime.now())
        ? state.user.expiresAt.add(Duration(days: days))
        : DateTime.now().add(Duration(days: days));

    final updated = state.user.copyWith(
      expiresAt: newExpiry,
      plan: plan,
    );

    await _saveProfile(updated);

    // Atualiza assinatura no Supabase
    await SupabaseService.instance.upsertSubscription(
      userId: updated.id,
      plan: plan,
      expiresAt: newExpiry,
      status: 'active',
      paymentMethod: 'manual',
    );

    state = state.copyWith(
      user: updated,
      successMessage: 'Assinatura renovada com sucesso! +$days dias ativados.',
    );
  }

  // ─── ATUALIZAR PERFIL ─────────────────────────────────────────────────────

  /// Atualiza o perfil e retorna true se o SERVIDOR aceitou.
  /// O estado local atualiza de todo jeito (tela mostra na hora); se o
  /// Supabase recusar, o erro real vai p/ errorMessage em vez de um
  /// "sucesso" mentiroso — era assim que dado "sumia" no restart.
  Future<bool> updateProfile({
    String? name,
    String? email,
    String? cpf,
    String? rg,
    String? phone,
    String? billingAddress,
    String? billingCep,
    String? cityUf,
  }) async {
    final updated = state.user.copyWith(
      name: name,
      email: email,
      cpf: cpf,
      rg: rg,
      phone: phone,
      billingAddress: billingAddress,
      billingCep: billingCep,
      cityUf: cityUf,
    );
    final remoteError = await _saveProfile(updated);
    if (remoteError == null) {
      state = state.copyWith(
        user: updated,
        successMessage: 'Perfil atualizado no banco de dados!',
        errorMessage: null,
      );
      return true;
    }
    state = state.copyWith(
      user: updated,
      errorMessage:
          'Salvo no aparelho, mas o servidor recusou: $remoteError',
      successMessage: null,
    );
    return false;
  }

  // ─── LOGOUT ───────────────────────────────────────────────────────────────

  Future<void> logout() async {
    HapticFeedback.mediumImpact();
    state = state.copyWith(isLoading: true);

    // Desloga no Supabase e no Google (cada um isolado p/ nunca travar)
    try {
      await SupabaseService.instance.signOut().timeout(
        const Duration(seconds: 6),
        onTimeout: () {},
      );
    } catch (_) {}
    try {
      await GoogleAuthService.instance.signOut().timeout(
        const Duration(seconds: 6),
        onTimeout: () {},
      );
    } catch (_) {}

    // Limpa 100% da sessão local: SQLite + prefs. Sem espelho, sem fantasma.
    try {
      await AppDatabase.instance.clearUserProfile();
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_kUserPrefKey);
    } catch (_) {}

    // Volta p/ convidado deslogado — a raiz (main) troca p/ Login sozinha,
    // e cada tela de saída empurra Login com pushAndRemoveUntil p/ zerar a pilha.
    state = state.copyWith(
      user: _guestProfile(),
      isBooting: false,
      isLoading: false,
      successMessage: null,
      errorMessage: null,
    );
  }
}

final authControllerProvider =
    StateNotifierProvider<AuthController, AuthState>((ref) {
  return AuthController();
});
