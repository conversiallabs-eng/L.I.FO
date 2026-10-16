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
      ).timeout(const Duration(seconds: 8));
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

  /// Salva ou atualiza os DADOS do usuário na tabela `user_profiles`.
  /// NUNCA envia plan/expires_at: plano e validade são propriedade do
  /// servidor (webhook/funções); o trigger trg_guard_money barra escrita
  /// dessas colunas por cliente (anti-calote).
  /// Retorna null em caso de sucesso ou a mensagem de erro real.
  /// Usa onConflict=auth_uid (único por login) p/ edição nunca virar INSERT
  /// duplicado nem esbarrar em UPDATE sem policy.
  Future<String?> upsertUserProfile(UserProfile profile) async {
    if (!_isInitialized || currentUser == null) {
      return 'Sem conexão com o servidor.';
    }
    final payload = <String, dynamic>{
      'id': profile.id,
      'auth_uid': currentUser!.id,
      'name': profile.name,
      'email': profile.email,
      'cpf': profile.cpf,
      'rg': profile.rg,
      'phone': profile.phone,
      'billing_address': profile.billingAddress,
      'billing_cep': profile.billingCep,
      'city_uf': profile.cityUf,
      'vehicle_type': profile.vehicleType,
      'avatar_url': profile.avatarUrl,
      'updated_at': DateTime.now().toIso8601String(),
    };
    try {
      await _client.from('user_profiles').upsert(
        payload,
        onConflict: 'auth_uid',
      );
      return null;
    } on PostgrestException catch (e) {
      // Se PostgREST acusar coluna ausente no cache de esquema, tenta salvar sem o campo problemático
      final match = RegExp(r"Could not find the '(\w+)' column").firstMatch(e.message);
      if (match != null) {
        final missingCol = match.group(1);
        if (missingCol != null && payload.containsKey(missingCol)) {
          try {
            final fallbackPayload = Map<String, dynamic>.from(payload)..remove(missingCol);
            await _client.from('user_profiles').upsert(
              fallbackPayload,
              onConflict: 'auth_uid',
            );
            return null;
          } catch (_) {}
        }
      }
      return e.message;
    } catch (e) {
      return e.toString().replaceFirst('Exception: ', '');
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

      final planRaw = data['plan'] as String?;
      final expiresRaw = data['expires_at'] as String?;
      final cpfRaw = data['cpf'] as String?;
      final cleanCpf = (cpfRaw ?? '').replaceAll(RegExp(r'\D'), '');
      final hasCpf = cleanCpf.length == 11;

      return UserProfile(
        id: data['id'] as String? ?? currentUser!.id,
        name: data['name'] as String? ?? currentUser!.email ?? 'Usuário',
        email: data['email'] as String? ?? currentUser!.email ?? '',
        plan: (hasCpf && planRaw != null) ? planRaw : 'Pendente de Ativação',
        expiresAt: (hasCpf && expiresRaw != null)
            ? (DateTime.tryParse(expiresRaw) ?? DateTime.now().subtract(const Duration(minutes: 1)))
            : DateTime.now().subtract(const Duration(minutes: 1)),
        avatarUrl: data['avatar_url'] as String?,
        vehicleType: data['vehicle_type'] as String? ?? 'Van de Carga',
        isLoggedIn: true,
        isGoogleAuth: false,
        cpf: cpfRaw,
        rg: data['rg'] as String?,
        phone: data['phone'] as String?,
        billingAddress: data['billing_address'] as String?,
        billingCep: data['billing_cep'] as String?,
        cityUf: data['city_uf'] as String?,
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

  /// Nome amigável do plano a partir da linha da tabela `subscriptions`.
  static String planDisplayName(Map<String, dynamic>? subscription) {
    if (subscription == null) {
      return 'Pendente de Ativação';
    }
    final t =
        (subscription['plan_type'] as String? ?? '').toLowerCase();
    if (t == 'pix_manual' || t == 'credit_card_auto') {
      return 'Standard (Ativo)';
    }
    if (t == 'trial') {
      return 'Standard (Trial 30 Dias)';
    }
    return 'Pendente de Ativação';
  }

  // ─── DINHEIRO NO SERVIDOR (anti-calote) ─────────────────────────────────
  // O app nunca escreve assinatura/plano/expiração: tudo via RPC/Edge
  // (fn_start_trial, fn_trust_grace_*, fn_apply_payment, confirm-renewal).
  // O trigger trg_guard_money barra qualquer escrita direta dessas colunas.

  /// Trial único por usuário e hardware (server-side; sem trial infinito).
  /// Recebe o [deviceFingerprint] para auditoria de 12 meses contra rodízio.
  /// Retorna o mapa da função ({ok, trial, expires_at, reason, message}) ou null sem rede.
  Future<Map<String, dynamic>?> startTrial({String? deviceFingerprint}) async {
    if (!_isInitialized || currentUser == null) return null;
    try {
      final res = await _client.rpc(
        'fn_start_trial',
        params: {
          if (deviceFingerprint != null && deviceFingerprint.isNotEmpty)
            'p_device_fingerprint': deviceFingerprint,
        },
      ).timeout(const Duration(seconds: 10));
      return (res as Map?)?.map((k, v) => MapEntry(k.toString(), v));
    } catch (_) {
      return null;
    }
  }

  /// Elegibilidade da confiança (servidor): {eligible, reason, ...}.
  Future<Map<String, dynamic>?> trustGraceStatus() async {
    if (!_isInitialized || currentUser == null) return null;
    try {
      final res = await _client
          .rpc('fn_trust_grace_status')
          .timeout(const Duration(seconds: 8));
      return (res as Map?)?.map((k, v) => MapEntry(k.toString(), v));
    } catch (_) {
      return null;
    }
  }

  /// Concede/reconcilia a confiança no servidor (idempotente).
  /// [deviceGrantedAt]: alegação do aparelho p/ graça provisória offline.
  Future<Map<String, dynamic>?> trustGraceGrant(
      {DateTime? deviceGrantedAt}) async {
    if (!_isInitialized || currentUser == null) return null;
    try {
      final res = await _client.rpc(
        'fn_trust_grace_grant',
        params: {
          'p_device_granted_at': deviceGrantedAt?.toIso8601String(),
        },
      ).timeout(const Duration(seconds: 10));
      return (res as Map?)?.map((k, v) => MapEntry(k.toString(), v));
    } catch (_) {
      return null;
    }
  }

  /// Confirma renovação pós-PIX no servidor (aplica dias com desconto da
  /// confiança e devolve a expiração oficial). O app usa o retorno — nunca
  /// calcula expiração local.
  Future<Map<String, dynamic>?> confirmRenewal({
    required String paymentId,
    DateTime? provisionalGrantedAt,
  }) async {
    if (!_isInitialized || currentUser == null) return null;
    try {
      final res = await _client.functions.invoke(
        'confirm-renewal',
        body: {
          'payment_id': paymentId,
          if (provisionalGrantedAt != null)
            'provisional_granted_at':
                provisionalGrantedAt.toIso8601String(),
        },
      ).timeout(const Duration(seconds: 25));
      if (res.status != 200 || res.data == null) return null;
      final data = res.data is String
          ? jsonDecode(res.data as String)
          : res.data;
      final map = (data as Map?)?.map((k, v) => MapEntry(k.toString(), v));
      if (map == null || map['error'] != null) return null;
      return map;
    } catch (_) {
      return null;
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
