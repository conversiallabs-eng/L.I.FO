import 'dart:convert';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../database/app_database.dart';
import '../../features/auth/domain/models/user_profile.dart';
import '../../features/route_manifest/domain/models/manifest_version.dart';

/// Credenciais do projeto LIFO no Supabase.
/// Project URL: https://sjbmweuszwxbkdimbwdg.supabase.co
const _kSupabaseUrl = 'https://sjbmweuszwxbkdimbwdg.supabase.co';
const _kSupabasePublishableKey =
    'sb_publishable_YyGwoRH_DbNAhs7E0oy2Aw_lFI8gk5e';

class SupabaseService {
  static final SupabaseService instance = SupabaseService._internal();
  SupabaseService._internal();

  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  SupabaseClient get _client => Supabase.instance.client;

  /// Usuário autenticado atual no Supabase Auth.
  User? get currentUser => _isInitialized ? _client.auth.currentUser : null;

  bool get isConnected =>
      _isInitialized && _client.auth.currentSession != null;

  // ─── INICIALIZAÇÃO ──────────────────────────────────────────────────────────

  Future<void> initialize() async {
    if (_isInitialized) return;
    try {
      await Supabase.initialize(
        url: _kSupabaseUrl,
        publishableKey: _kSupabasePublishableKey,
      );
      _isInitialized = true;
    } catch (e) {
      _isInitialized = false;
    }
  }

  // ─── AUTENTICAÇÃO ──────────────────────────────────────────────────────────

  /// Cadastra um novo usuário com e-mail e senha no Supabase Auth.
  /// Retorna o [User] criado ou null em caso de erro.
  Future<User?> signUp({
    required String email,
    required String password,
    required String name,
  }) async {
    if (!_isInitialized) return null;
    try {
      final response = await _client.auth.signUp(
        email: email,
        password: password,
        data: {'full_name': name},
      );
      return response.user;
    } catch (_) {
      return null;
    }
  }

  /// Faz login com e-mail e senha.
  Future<User?> signInWithEmail({
    required String email,
    required String password,
  }) async {
    if (!_isInitialized) return null;
    try {
      final response = await _client.auth.signInWithPassword(
        email: email,
        password: password,
      );
      return response.user;
    } catch (_) {
      return null;
    }
  }

  /// Faz logout do usuário atual.
  Future<void> signOut() async {
    if (!_isInitialized) return;
    try {
      await _client.auth.signOut();
    } catch (_) {}
  }

  /// Tenta renovar a sessão com o refresh token salvo (cold start com
  /// access token expirado). Retorna o [User] ou null se não há sessão.
  Future<User?> refreshSession() async {
    if (!_isInitialized) return null;
    try {
      final response = await _client.auth.refreshSession();
      return response.user;
    } catch (_) {
      return null;
    }
  }

  /// Envia e-mail de recuperação de senha.
  Future<bool> resetPassword(String email) async {
    if (!_isInitialized) return false;
    try {
      await _client.auth.resetPasswordForEmail(email);
      return true;
    } catch (_) {
      return false;
    }
  }

  // ─── PERFIL DE USUÁRIO ────────────────────────────────────────────────────

  /// Salva ou atualiza o perfil do usuário na tabela `user_profiles` do Supabase.
  Future<bool> upsertUserProfile(UserProfile profile) async {
    if (!_isInitialized || currentUser == null) return false;
    try {
      await _client.from('user_profiles').upsert({
        'id': profile.id,
        'auth_uid': currentUser!.id,
        'name': profile.name,
        'email': profile.email,
        'cpf': profile.cpf,
        'rg': profile.rg,
        'phone': profile.phone,
        'billing_address': profile.billingAddress,
        'billing_cep': profile.billingCep,
        'vehicle_type': profile.vehicleType,
        'avatar_url': profile.avatarUrl,
        'plan': profile.plan,
        'expires_at': profile.expiresAt.toIso8601String(),
        'fcm_token': profile.fcmToken,
        'updated_at': DateTime.now().toIso8601String(),
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Busca o perfil do usuário logado na tabela `user_profiles` do Supabase.
  Future<UserProfile?> fetchUserProfile() async {
    if (!_isInitialized || currentUser == null) return null;
    try {
      final data = await _client
          .from('user_profiles')
          .select()
          .eq('auth_uid', currentUser!.id)
          .maybeSingle();

      if (data == null) return null;

      return UserProfile(
        id: data['id'] as String? ?? currentUser!.id,
        name: data['name'] as String? ?? currentUser!.email ?? 'Usuário',
        email: data['email'] as String? ?? currentUser!.email ?? '',
        plan: data['plan'] as String? ?? 'Standard (Trial 30 Dias)',
        expiresAt: DateTime.tryParse(data['expires_at'] as String? ?? '') ??
            DateTime.now().add(const Duration(days: 30)),
        avatarUrl: data['avatar_url'] as String?,
        vehicleType: data['vehicle_type'] as String? ?? 'Van de Carga',
        isLoggedIn: true,
        isGoogleAuth: false,
        cpf: data['cpf'] as String?,
        rg: data['rg'] as String?,
        phone: data['phone'] as String?,
        billingAddress: data['billing_address'] as String?,
        billingCep: data['billing_cep'] as String?,
        fcmToken: data['fcm_token'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  // ─── ASSINATURAS ──────────────────────────────────────────────────────────

  /// Verifica se o usuário tem assinatura ativa na tabela `subscriptions`.
  Future<Map<String, dynamic>?> fetchSubscription() async {
    if (!_isInitialized || currentUser == null) return null;
    try {
      final data = await _client
          .from('subscriptions')
          .select()
          .eq('user_id', currentUser!.id)
          .maybeSingle();
      return data;
    } catch (_) {
      return null;
    }
  }

  /// Cria ou atualiza uma assinatura no Supabase.
  Future<bool> upsertSubscription({
    required String userId,
    required String plan,
    required DateTime expiresAt,
    required String status, // 'trial', 'active', 'expired', 'cancelled'
    String paymentMethod = 'manual',
  }) async {
    if (!_isInitialized) return false;
    try {
      await _client.from('subscriptions').upsert({
        'user_id': userId,
        'plan': plan,
        'expires_at': expiresAt.toIso8601String(),
        'status': status,
        'payment_method': paymentMethod,
        'updated_at': DateTime.now().toIso8601String(),
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  // ─── SYNC QUEUE (MANIFESTS) ───────────────────────────────────────────────

  Future<int> processSyncQueue() async {
    if (!_isInitialized) return 0;

    final pending = await AppDatabase.instance.getPendingSyncQueue();
    int syncedCount = 0;

    for (final item in pending) {
      final id = item['id'] as String;
      final entityType = item['entity_type'] as String;
      final action = item['action'] as String;
      final payload =
          jsonDecode(item['payload'] as String) as Map<String, dynamic>;

      try {
        if (action == 'insert' || action == 'upsert') {
          await _client.from(entityType).upsert(payload);
        } else if (action == 'update') {
          await _client
              .from(entityType)
              .update(payload)
              .eq('id', payload['id']);
        }
        await AppDatabase.instance.markQueueItemSynced(id);
        syncedCount++;
      } catch (_) {}
    }

    return syncedCount;
  }

  Future<bool> pushManifestVersion(ManifestVersion version) async {
    if (!_isInitialized) return false;

    try {
      await _client.from('manifest_versions').upsert(version.toMap());
      for (final stop in version.stops) {
        await _client.from('delivery_stops').upsert(stop.toMap());
        for (final pkg in stop.packages) {
          await _client.from('package_items').upsert(pkg.toMap());
        }
      }
      return true;
    } catch (_) {
      return false;
    }
  }
}
