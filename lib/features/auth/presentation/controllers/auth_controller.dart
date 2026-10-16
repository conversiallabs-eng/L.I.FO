import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../../../../core/network/net_guard.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/network/supabase_service.dart';
import '../../../../core/security/license_guard.dart';
import '../../../../core/services/device_security_service.dart';
import '../../../../core/utils/cpf_validator.dart';
import '../../data/services/google_auth_service.dart';
import '../../domain/models/user_profile.dart';

const String _kUserPrefKey = 'lifo_user_profile';
const String _kDeviceIdKey = 'lifo_device_id_v1';
// Confiança ("libere e pague"): chaves por usuário (sufixo = user id).
const String _kHasPaidPrefix = 'lifo_has_paid_';
const String _kGracePendingPrefix = 'lifo_grace_pending_';
const String _kGraceDaysPrefix = 'lifo_grace_days_';
const String _kGraceSuffix = '_v1';

/// Dias liberados na confiança. O pagamento seguinte desconta o adiantado
/// (ex.: mensal 30d → renova 25d).
const int kTrustGraceDays = 5;

class AuthState {
  final UserProfile user;
  final bool isLoading;
  final bool isBooting;
  final bool isOffline;
  /// Expirado com confiança disponível: a Home abre a renovação travada
  /// (PIX + "libere e pague") em vez de deixar usar.
  final bool graceOfferPending;
  final String? errorMessage;
  final String? successMessage;

  const AuthState({
    required this.user,
    this.isLoading = false,
    this.isBooting = false,
    this.isOffline = false,
    this.graceOfferPending = false,
    this.errorMessage,
    this.successMessage,
  });

  AuthState copyWith({
    UserProfile? user,
    bool? isLoading,
    bool? isBooting,
    bool? isOffline,
    bool? graceOfferPending,
    String? errorMessage,
    String? successMessage,
  }) {
    return AuthState(
      user: user ?? this.user,
      isLoading: isLoading ?? this.isLoading,
      isBooting: isBooting ?? this.isBooting,
      isOffline: isOffline ?? this.isOffline,
      graceOfferPending: graceOfferPending ?? this.graceOfferPending,
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
  // Offline-first: Supabase é a fonte da verdade quando há rede; sem rede,
  // o cache local (SQLite/prefs) com token válido libera o app.
  // Login em si SEMPRE exige internet — o fallback só vale para sessão já
  // existente. Expirado com confiança disponível ENTRA travado no PIX
  // (graceOfferPending); expirado sem confiança bloqueia no Login.

  static const String _kLastSyncKey = 'lifo_last_online_sync_ms';
  static const String _kLastClockKey = 'lifo_sec_monotonic_epoch_v1';

  Future<void> _loadProfile() async {
    try {
      // Fast-path offline: sem conectividade, nem tenta rede.
      if (await isOfflineFast()) {
        debugPrint('AuthBoot: sem conectividade, direto ao cache local…');
        final local = await _loadLocalFallback();
        if (local != null) {
          state = state.copyWith(
            user: local,
            isBooting: false,
            isOffline: true,
          );
          return;
        }
        // Expirado com confiança: entra travado no PIX (oferta na tela).
        final grace = await _loadExpiredForGrace();
        state = state.copyWith(
          user: grace ?? _guestProfile(),
          isBooting: false,
          isOffline: grace != null,
          graceOfferPending: grace != null,
        );
        return;
      }

      // 0. Garante o Supabase iniciado (se o boot foi sem rede, tenta de novo
      // com timeout curto para nunca travar o boot offline).
      if (!SupabaseService.instance.isInitialized) {
        debugPrint('AuthBoot: Supabase não iniciou no main, retentando…');
        try {
          await SupabaseService.instance
              .initialize()
              .timeout(const Duration(seconds: 4));
        } catch (_) {}
      }

      // 1. Aguarda a sessão persistida voltar (storage local é async).
      var supaUser = SupabaseService.instance.currentUser;
      for (var i = 0; supaUser == null && i < 15; i++) {
        await Future.delayed(const Duration(milliseconds: 200));
        supaUser = SupabaseService.instance.currentUser;
      }
      if (supaUser == null) {
        // 2. Nada restaurado: tenta renovar com o refresh token salvo
        // (access token expirado entre um boot e outro). Sem rede isso
        // falha rápido — cai no fallback offline abaixo.
        debugPrint('AuthBoot: sem sessão restaurada, tentando refresh…');
        try {
          supaUser = await SupabaseService.instance
              .refreshSession()
              .timeout(const Duration(seconds: 5));
        } catch (_) {
          supaUser = null;
        }
      }

      if (supaUser != null) {
        // 3. Sessão OK: busca o perfil com retentativas (rede no boot falha
        // direto — era isso que derrubava o login "permanente").
        // Cada tentativa tem timeout próprio: sem isso, o postgrest pendura
        // o splash por dezenas de segundos com rádio ligado e sem rota.
        debugPrint('AuthBoot: sessão de ${supaUser.email}, buscando perfil…');
        for (var attempt = 1; attempt <= 3; attempt++) {
          try {
            final remoteProfile = await SupabaseService.instance
                .fetchUserProfile()
                .timeout(const Duration(seconds: 5));
            if (remoteProfile != null) {
              debugPrint('AuthBoot: perfil restaurado (online).');
              final cleanCpf = (remoteProfile.cpf ?? '').replaceAll(RegExp(r'\D'), '');
              final hasValidCpf = cleanCpf.length == 11 && CpfValidator.isValid(cleanCpf);
              final isPending = !hasValidCpf || remoteProfile.plan.toLowerCase().contains('pendente');
              final effectiveProfile = isPending
                  ? remoteProfile.copyWith(
                      plan: 'Pendente de Ativação',
                      expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
                    )
                  : remoteProfile;

              await _recordOnlineSync();
              await _issueOfflineToken(effectiveProfile);
              state = state.copyWith(
                user: effectiveProfile,
                isBooting: false,
                isOffline: false,
              );
              // Reconcilia provisória e espelha o status oficial da graça.
              // (Se revogar, o estado já foi trocado — não sobrescreve.)
              await _reconcileProvisionalGrace();
              if (state.user.id != remoteProfile.id ||
                  !state.user.isLoggedIn) {
                return;
              }
              // Expirado online: oferta conforme o SERVIDOR.
              if (!remoteProfile.expiresAt.isAfter(DateTime.now())) {
                var offer = false;
                try {
                  final s = await SupabaseService.instance
                      .trustGraceStatus()
                      .timeout(const Duration(seconds: 6));
                  offer = s?['eligible'] == true;
                } catch (_) {
                  offer = await _graceAvailableFor(remoteProfile);
                }
                state = state.copyWith(graceOfferPending: offer);
              }
              return;
            }
          } catch (_) {}
          // Só espera e tenta de novo se a sessão continua válida.
          if (SupabaseService.instance.currentUser == null) break;
          debugPrint(
              'AuthBoot: perfil tentativa $attempt falhou, retentando…');
          await Future.delayed(const Duration(seconds: 1));
        }
        // Sessão válida mas perfil inalcançável (offline?) — tenta o cache
        // local do MESMO usuário antes de desistir.
        final localSameUser = await _loadLocalFallback(
          requireUserId: supaUser.id,
        );
        if (localSameUser != null) {
          debugPrint('AuthBoot: offline com sessão, usando cache local.');
          state = state.copyWith(
            user: localSameUser,
            isBooting: false,
            isOffline: true,
          );
          return;
        }
        // Expirado com confiança: entra travado no PIX.
        final graceSameUser =
            await _loadExpiredForGrace(requireUserId: supaUser.id);
        if (graceSameUser != null) {
          state = state.copyWith(
            user: graceSameUser,
            isBooting: false,
            isOffline: true,
            graceOfferPending: true,
          );
          return;
        }
        debugPrint('AuthBoot: sessão válida mas sem perfil no servidor.');
        final pendingUser = UserProfile(
          id: supaUser.id,
          name: supaUser.userMetadata?['full_name'] as String? ??
              supaUser.email?.split('@').first ?? 'Usuário',
          email: supaUser.email ?? '',
          plan: 'Pendente de Ativação',
          expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
          isLoggedIn: true,
          isGoogleAuth: supaUser.appMetadata['provider'] == 'google',
        );
        await OfflineLicenseGuard.clearLicenseToken();
        state = state.copyWith(
          user: pendingUser,
          isBooting: false,
          isOffline: false,
        );
        return;
      }

      // 4. Sem sessão Supabase (offline frio ou nunca logou): fallback local.
      // Se já logou antes e o plano não venceu, o app ABRE offline.
      debugPrint('AuthBoot: sem sessão, tentando cache local offline…');
      final local = await _loadLocalFallback();
      if (local != null) {
        debugPrint('AuthBoot: offline-first, sessão local válida.');
        state = state.copyWith(
          user: local,
          isBooting: false,
          isOffline: true,
        );
        return;
      }
      // Expirado com confiança: entra travado no PIX.
      final grace = await _loadExpiredForGrace();
      if (grace != null) {
        state = state.copyWith(
          user: grace,
          isBooting: false,
          isOffline: true,
          graceOfferPending: true,
        );
        return;
      }
      debugPrint('AuthBoot: sem sessão (login necessário).');
    } catch (e) {
      debugPrint('AuthBoot: erro $e');
      // Última chance: cache local mesmo em exceção inesperada.
      final local = await _loadLocalFallback();
      if (local != null) {
        state = state.copyWith(
          user: local,
          isBooting: false,
          isOffline: true,
        );
        return;
      }
      final grace = await _loadExpiredForGrace();
      if (grace != null) {
        state = state.copyWith(
          user: grace,
          isBooting: false,
          isOffline: true,
          graceOfferPending: true,
        );
        return;
      }
    }
    state = state.copyWith(
      user: _guestProfile(),
      isBooting: false,
      isOffline: false,
    );
  }

  /// ID estável do aparelho (gerado 1x, guardado em prefs). Amarra o token
  /// offline a esta instalação — limpar os dados do app apaga cache + token
  /// juntos, forçando novo login online. Não é apagado no logout.
  Future<String> _getOrCreateDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_kDeviceIdKey);
    if (id == null || id.isEmpty) {
      id = const Uuid().v4();
      try {
        await prefs.setString(_kDeviceIdKey, id);
      } catch (_) {}
    }
    return id;
  }

  /// Emite e instala o token offline assinado (payload HMAC-SHA256 com
  /// `expires_at` + `device_id`). Chamado em todo sucesso ONLINE
  /// (login, cadastro, renovação, revalidação) com a validade vinda do
  /// servidor — nunca inventada localmente.
  Future<void> _issueOfflineToken(UserProfile profile) async {
    try {
      final cleanCpf = (profile.cpf ?? '').replaceAll(RegExp(r'\D'), '');
      final hasValidCpf =
          cleanCpf.length == 11 && CpfValidator.isValid(cleanCpf);
      // Se não possui CPF válido ou o plano está pendente, limpa qualquer token antigo do aparelho
      if (!hasValidCpf || profile.plan.toLowerCase().contains('pendente')) {
        await OfflineLicenseGuard.clearLicenseToken();
        return;
      }
      final deviceId = await _getOrCreateDeviceId();
      final token = OfflineLicenseGuard.createSignedToken(
        userId: profile.id,
        deviceId: deviceId,
        plan: profile.plan,
        expiresAt: profile.expiresAt,
      );
      await OfflineLicenseGuard.installLicenseToken(token);
    } catch (_) {}
  }

  /// Lê SQLite → prefs e valida o TOKEN offline assinado.
  /// Retorna o perfil somente se: logado + relógio íntegro + assinatura
  /// válida + `expires_at` do token no futuro (validade pela hora do
  /// aparelho, com anti-rollback de ±30s). Expirado bloqueia mesmo offline.
  /// Com [requireUserId], só aceita o cache do mesmo usuário da sessão.
  Future<UserProfile?> _loadLocalFallback({String? requireUserId}) async {
    try {
      UserProfile? cached;
      try {
        cached = await AppDatabase.instance.getUserProfile().timeout(
          const Duration(seconds: 4),
        );
      } catch (_) {}
      cached ??= await _loadPrefsProfile();

      if (cached == null || !cached.isLoggedIn) return null;
      if (requireUserId != null &&
          cached.id != requireUserId &&
          cached.id != 'guest') {
        // Cache de outro usuário — não ressuscita sessão trocada.
        // (Após logout o cache é limpo, então isso só ocorre em edge cases.)
        return null;
      }

      // Trava de segurança: se o cache local não possui CPF válido ou está
      // com plano pendente, invalida qualquer trial antigo herdado do aparelho.
      final cleanCpf = (cached.cpf ?? '').replaceAll(RegExp(r'\D'), '');
      final hasValidCpf =
          cleanCpf.length == 11 && CpfValidator.isValid(cleanCpf);
      if (!hasValidCpf) {
        cached = cached.copyWith(
          plan: 'Pendente de Ativação',
          expiresAt: DateTime.now().subtract(const Duration(minutes: 1)),
        );
      }

      // Se está pendente de ativação, devolve o perfil logado para que
      // o app exiba obrigatoriamente a tela de KYC (CompleteRegistrationScreen).
      if (cached.plan.toLowerCase().contains('pendente')) {
        return cached.copyWith(isLoggedIn: true);
      }

      // Cinturão: expiração do próprio cache (vale pela hora do aparelho).
      if (!cached.expiresAt.isAfter(DateTime.now())) {
        debugPrint(
            'AuthBoot: cache local expirado em ${cached.expiresAt}, bloqueando.');
        return null;
      }

      final deviceId = await _getOrCreateDeviceId();
      var result = await OfflineLicenseGuard.validateOffline(
        currentDeviceFingerprint: deviceId,
      );

      // Migração: quem logou antes do token existir tem cache válido mas sem
      // token. Emite 1x a partir do cache (relógio já checado acima como são)
      // para não trancar quem está offline agora.
      if (result.status == LicenseStatus.missingToken) {
        debugPrint('AuthBoot: sem token, emitindo a partir do cache (1x)…');
        await _issueOfflineToken(cached);
        result = await OfflineLicenseGuard.validateOffline(
          currentDeviceFingerprint: deviceId,
        );
      }

      if (!result.isValid) {
        debugPrint('AuthBoot: token offline ${result.status}, bloqueando.');
        return null;
      }
      // Alinha a expiração exibida com a do token validado.
      final expiresAt = result.expiresAt;
      return cached.copyWith(
        isLoggedIn: true,
        expiresAt: expiresAt,
      );
    } catch (_) {
      return null;
    }
  }

  Future<UserProfile?> _loadPrefsProfile() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kUserPrefKey);
      if (raw == null || raw.isEmpty) return null;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return UserProfile.fromMap(map);
    } catch (_) {
      return null;
    }
  }

  // ─── CONFIANÇA ("LIBERE E PAGUE") ──────────────────────────────────────
  // Expirado que JÁ PAGOU pelo menos 1x pode entrar, mas trava na tela do
  // PIX com a oferta: +5 dias na confiança ("o LIFO confia em você").
  // O pagamento seguinte desconta o adiantado (30d → renova 25d).
  // Trial sem nenhum pagamento nunca tem confiança. E sem pagar a anterior,
  // não há nova confiança (trava o loop de 5 dias grátis infinito).

  Future<void> _markPaidOnce(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('$_kHasPaidPrefix$userId$_kGraceSuffix', true);
    } catch (_) {}
  }

  /// Verdade se o usuário já pagou 1x (registro local ou plano pago ativo).
  Future<bool> _hasPaidOnceFor(UserProfile p) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('$_kHasPaidPrefix${p.id}$_kGraceSuffix') == true) {
        return true;
      }
    } catch (_) {}
    // Plano pago ativo (ex.: "Standard (Ativo)") — trial não contém "ativo".
    return p.plan.toLowerCase().contains('ativo');
  }

  Future<int> _graceAdvancedDays(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('$_kGracePendingPrefix$userId$_kGraceSuffix') != true) {
        return 0;
      }
      return prefs.getInt('$_kGraceDaysPrefix$userId$_kGraceSuffix') ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Pode OFERECER a confiança? Expirado + pagou 1x + sem adiantamento aberto.
  Future<bool> _graceAvailableFor(UserProfile p) async {
    if (!p.isLoggedIn) return false;
    if (p.expiresAt.isAfter(DateTime.now())) return false;
    if (!(await _hasPaidOnceFor(p))) return false;
    return (await _graceAdvancedDays(p.id)) <= 0;
  }

  /// Para a tela: pode TOMAR a confiança agora? (expirado + elegível)
  /// Online o SERVIDOR decide; offline vale o espelho local.
  Future<bool> canTakeGrace() async {
    final u = state.user;
    if (!u.isLoggedIn || u.expiresAt.isAfter(DateTime.now())) return false;
    if (!(await isOfflineFast())) {
      try {
        final s = await SupabaseService.instance.trustGraceStatus();
        if (s != null) {
          // Espelha o servidor localmente (para o próximo offline).
          try {
            final prefs = await SharedPreferences.getInstance();
            if (s['open_grace'] != null) {
              await prefs.setBool(
                  '$_kGracePendingPrefix${u.id}$_kGraceSuffix', true);
            } else {
              await _clearGraceMirror(u.id);
            }
          } catch (_) {}
          return s['eligible'] == true;
        }
      } catch (_) {}
    }
    if (!(await _hasPaidOnceFor(u))) return false;
    return (await _graceAdvancedDays(u.id)) <= 0;
  }

  /// Já usou a confiança e ainda não pagou? (mostra aviso em vez do botão)
  /// Online o servidor manda; offline vale o espelho local.
  Future<bool> isGracePending() async {
    if (!(await isOfflineFast())) {
      try {
        final s = await SupabaseService.instance.trustGraceStatus();
        if (s != null) return s['open_grace'] != null;
      } catch (_) {}
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(
            '$_kGracePendingPrefix${state.user.id}$_kGraceSuffix',
          ) ==
          true;
    } catch (_) {
      return false;
    }
  }

  /// Cache expirado que pode entrar na confiança (ignora validade/token —
  /// a oferta é decidida na tela do PIX; sem elegibilidade retorna null).
  Future<UserProfile?> _loadExpiredForGrace({String? requireUserId}) async {
    try {
      UserProfile? cached;
      try {
        cached = await AppDatabase.instance.getUserProfile().timeout(
          const Duration(seconds: 4),
        );
      } catch (_) {}
      cached ??= await _loadPrefsProfile();
      if (cached == null || !cached.isLoggedIn) return null;
      if (requireUserId != null &&
          cached.id != requireUserId &&
          cached.id != 'guest') {
        return null;
      }
      if (!(await _graceAvailableFor(cached))) return null;
      return cached;
    } catch (_) {
      return null;
    }
  }

  /// Concede +5 dias na confiança ("o LIFO confia em você").
  /// ONLINE: o servidor decide e REGISTRA (fn_trust_grace_grant) — vale a
  /// expiração oficial devolvida. OFFLINE: provisório local, reconciliado
  /// no próximo contato (abuso é revogado). Só expirado toma.
  Future<bool> grantTrustGrace() async {
    final user = state.user;
    if (!user.isLoggedIn || user.expiresAt.isAfter(DateTime.now())) {
      return false;
    }
    // ONLINE: servidor manda (elegibilidade + ledger).
    if (!(await isOfflineFast())) {
      try {
        final res = await SupabaseService.instance.trustGraceGrant();
        if (res == null || res['ok'] != true) return false;
        final exp = DateTime.tryParse(res['expires_at'] as String? ?? '');
        if (exp == null) return false;
        final updated = user.copyWith(expiresAt: exp);
        await _saveProfileLocal(updated);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(
            '$_kGracePendingPrefix${user.id}$_kGraceSuffix', true);
        await prefs.setInt('$_kGraceDaysPrefix${user.id}$_kGraceSuffix',
            (res['days'] as num?)?.toInt() ?? kTrustGraceDays);
        await prefs.remove(
            'lifo_grace_provisional_at_${user.id}$_kGraceSuffix');
        await _issueOfflineToken(updated);
        state = state.copyWith(
          user: updated,
          graceOfferPending: false,
          successMessage:
              'Liberado por $kTrustGraceDays dias na confiança! Bom trabalho.',
        );
        HapticFeedback.mediumImpact();
        return true;
      } catch (_) {
        return false;
      }
    }
    // OFFLINE provisório — só se localmente elegível; reconcilia depois.
    if (!(await _hasPaidOnceFor(user))) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('$_kGracePendingPrefix${user.id}$_kGraceSuffix') ==
          true) {
        return false; // adiantamento aberto: precisa pagar antes de outro.
      }
      final now = DateTime.now();
      final updated =
          user.copyWith(expiresAt: now.add(const Duration(days: kTrustGraceDays)));
      await _saveProfileLocal(updated);
      await prefs.setBool(
          '$_kGracePendingPrefix${user.id}$_kGraceSuffix', true);
      await prefs.setInt('$_kGraceDaysPrefix${user.id}$_kGraceSuffix',
          kTrustGraceDays);
      await prefs.setString(
          'lifo_grace_provisional_at_${user.id}$_kGraceSuffix',
          now.toIso8601String());
      await _issueOfflineToken(updated);
      state = state.copyWith(
        user: updated,
        graceOfferPending: false,
        successMessage:
            'Liberado por $kTrustGraceDays dias na confiança! Bom trabalho.',
      );
      HapticFeedback.mediumImpact();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Reconcilia graça provisória com o servidor (chamado ao reconectar e no
  /// boot online). Se o servidor recusar (abuso), REVOGA o local e trava.
  /// Retorna true se há graça válida ao final (registrada ou sem pendência).
  Future<bool> _reconcileProvisionalGrace() async {
    try {
      final user = state.user;
      if (!user.isLoggedIn) return true;
      final provisional = await _provisionalGrantedAt(user.id);
      // Espelha o status oficial (quita/baixa o espelho local).
      try {
        final status = await SupabaseService.instance.trustGraceStatus();
        if (status != null) {
          final prefs = await SharedPreferences.getInstance();
          if (status['open_grace'] != null) {
            await prefs.setBool(
                '$_kGracePendingPrefix${user.id}$_kGraceSuffix', true);
          } else {
            await _clearGraceMirror(user.id);
          }
        }
      } catch (_) {}
      if (provisional == null) return true;
      // Há provisória a reconciliar: o servidor valida e registra.
      final res = await SupabaseService.instance.trustGraceGrant(
        deviceGrantedAt: provisional,
      );
      if (res != null && res['ok'] == true) {
        final exp = DateTime.tryParse(res['expires_at'] as String? ?? '');
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(
            'lifo_grace_provisional_at_${user.id}$_kGraceSuffix');
        if (exp != null) {
          final aligned = user.copyWith(expiresAt: exp);
          await _saveProfileLocal(aligned);
          await _issueOfflineToken(aligned);
          state = state.copyWith(user: aligned);
        }
        debugPrint('Auth: graça provisória reconciliada no servidor.');
        return true;
      }
      // Servidor recusou: revoga o local (trava na hora).
      debugPrint('Auth: graça recusada pelo servidor, revogando local.');
      await _revokeLocalGrace();
      return false;
    } catch (_) {
      return true;
    }
  }

  /// Apaga token + espelho da confiança e desloga (sem oferta).
  /// O main roteia p/ o Login.
  Future<void> _revokeLocalGrace() async {
    try {
      await OfflineLicenseGuard.clearLicenseToken();
      await _clearGraceMirror(state.user.id);
    } catch (_) {}
    state = state.copyWith(
      user: _guestProfile(),
      isBooting: false,
      isOffline: false,
      graceOfferPending: false,
      errorMessage: 'Confiança não reconhecida pelo servidor. Renove para continuar.',
    );
  }

  Future<void> _recordOnlineSync() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      await prefs.setInt(_kLastSyncKey, nowMs);
      await prefs.setInt(_kLastClockKey, nowMs);
    } catch (_) {}
  }

  /// Chamado ao reconectar: se estamos em modo offline, tenta revalidar
  /// a sessão/perfil/assinatura no servidor sem trocar de tela. Se o plano
  /// venceu no servidor, o estado passa a refletir a expiração (e o token
  /// offline é reemitido com a nova validade).
  Future<void> revalidateWhenOnline() async {
    if (!state.user.isLoggedIn || !state.isOffline) return;
    try {
      if (!SupabaseService.instance.isInitialized) {
        await SupabaseService.instance.initialize();
      }
      final supaUser = SupabaseService.instance.currentUser ??
          await SupabaseService.instance.refreshSession();
      if (supaUser == null) return;
      final remote = await SupabaseService.instance.fetchUserProfile();
      if (remote == null) return;
      // Mescla a assinatura como no login: revogação no servidor precisa
      // derrubar o acesso, não só a expiração por data.
      DateTime expiresAt = remote.expiresAt;
      String plan = remote.plan;
      try {
        final subscription =
            await SupabaseService.instance.fetchSubscription();
        if (subscription != null) {
          plan = SupabaseService.planDisplayName(subscription);
          expiresAt = DateTime.tryParse(
                subscription['expires_at'] as String? ?? '',
              ) ??
              remote.expiresAt;
        }
      } catch (_) {}
      final merged =
          remote.copyWith(plan: plan, expiresAt: expiresAt, isLoggedIn: true);
      await _recordOnlineSync();
      await _saveProfile(merged);
      await _issueOfflineToken(merged);
      state = state.copyWith(user: merged, isOffline: false);
      // Reconcilia graça provisória (abuso é revogado e trava na hora).
      final graceOk = await _reconcileProvisionalGrace();
      if (!graceOk) return;
      // Ainda expirado? Oferta da confiança conforme o servidor.
      if (!merged.expiresAt.isAfter(DateTime.now())) {
        var offer = false;
        try {
          final s = await SupabaseService.instance.trustGraceStatus();
          offer = s?['eligible'] == true;
        } catch (_) {
          offer = await _graceAvailableFor(merged);
        }
        if (offer) {
          state = state.copyWith(graceOfferPending: true);
        }
      }
      debugPrint('Auth: revalidado online, saindo do modo offline.');
    } catch (_) {}
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
    // (Só dados cadastrais: plan/expires o payload nem envia — servidor manda.)
    try {
      final err = await SupabaseService.instance.upsertUserProfile(profile);
      if (err == null) await _recordOnlineSync();
      return err;
    } catch (e) {
      return e.toString().replaceFirst('Exception: ', '');
    }
  }

  /// Espelho SOMENTE local (SQLite + prefs), sem tocar o servidor.
  /// Para aplicar verdade vinda do servidor (renovação, reconcile).
  Future<void> _saveProfileLocal(UserProfile profile) async {
    try {
      await AppDatabase.instance.saveUserProfile(profile);
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kUserPrefKey, jsonEncode(profile.toMap()));
    } catch (_) {}
  }

  /// Instante da graça provisória (concedida offline, p/ reconciliar).
  Future<DateTime?> _provisionalGrantedAt(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('lifo_grace_provisional_at_$userId$_kGraceSuffix');
      if (raw == null || raw.isEmpty) return null;
      return DateTime.tryParse(raw);
    } catch (_) {
      return null;
    }
  }

  /// Limpa o espelho local da confiança (paga ou revogada).
  Future<void> _clearGraceMirror(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('$_kGracePendingPrefix$userId$_kGraceSuffix', false);
      await prefs.remove('lifo_grace_provisional_at_$userId$_kGraceSuffix');
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

      // Sem conta no Supabase, sem cadastro (única fonte da verdade).
      if (supaUser == null) {
        state = state.copyWith(
          isLoading: false,
          errorMessage: 'Não foi possível criar a conta no servidor.',
        );
        return false;
      }

      final userId = supaUser.id;

      final cleanCpf = (cpf ?? '').replaceAll(RegExp(r'\D'), '');
      final hasValidCpf =
          cleanCpf.length == 11 && CpfValidator.isValid(cleanCpf);

      if (!hasValidCpf) {
        state = state.copyWith(
          isLoading: false,
          errorMessage:
              'CPF obrigatório e inválido. Digite um CPF válido com 11 dígitos.',
        );
        return false;
      }

      var newUser = UserProfile(
        id: userId,
        name: name.trim(),
        email: email.trim().toLowerCase(),
        plan: 'Pendente de Ativação',
        expiresAt: DateTime.now(), // Inicia estritamente com 0 dias!
        isLoggedIn: true,
        isGoogleAuth: false,
        vehicleType: vehicleType ?? 'Van de Carga',
        cpf: cleanCpf,
        rg: rg,
        phone: phone,
        billingAddress: billingAddress,
        billingCep: billingCep,
      );

      final remoteErr = await _saveProfile(newUser);
      if (remoteErr != null) {
        String msg = remoteErr;
        if (remoteErr.contains('uq_user_profiles_clean_cpf') ||
            remoteErr.contains('duplicate key') ||
            remoteErr.contains('23505')) {
          msg = 'Este CPF já está cadastrado em outra conta L.I.F.O.';
        }
        state = state.copyWith(
          isLoading: false,
          errorMessage: msg,
        );
        return false;
      }

      // Trial único via servidor com validação de Hardware (anti-rodízio)
      try {
        final fp = await DeviceSecurityService.instance.getDeviceFingerprint();
        final trial =
            await SupabaseService.instance.startTrial(deviceFingerprint: fp);
        if (trial != null && trial['ok'] == false) {
          final msg = trial['message'] as String? ??
              'Período de teste já utilizado neste CPF ou aparelho nos últimos 12 meses.';
          final expiredUser = newUser.copyWith(
            expiresAt: DateTime.now().subtract(const Duration(hours: 1)),
            plan: 'Assinatura Necessária',
          );
          await _saveProfile(expiredUser);
          state = state.copyWith(
            user: expiredUser,
            isLoading: false,
            errorMessage: msg,
          );
          return false;
        }
        final exp = DateTime.tryParse(trial?['expires_at'] as String? ?? '');
        if (trial?['ok'] == true && exp != null) {
          newUser = newUser.copyWith(
            plan: 'Standard (Trial 30 Dias)',
            expiresAt: exp,
          );
          await _saveProfile(newUser);
          await _issueOfflineToken(newUser);
          state = state.copyWith(
            user: newUser,
            isLoading: false,
            isOffline: false,
            successMessage: 'Conta criada! 30 dias de trial liberados.',
          );
          HapticFeedback.mediumImpact();
          return true;
        } else {
          state = state.copyWith(
            user: newUser,
            isLoading: false,
            errorMessage: trial?['message'] ??
                'Não foi possível ativar o período de teste.',
          );
          return false;
        }
      } catch (_) {
        state = state.copyWith(
          user: newUser,
          isLoading: false,
          errorMessage: 'Erro ao validar período de teste com o servidor.',
        );
        return false;
      }
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorMessage:
            'Erro ao criar conta. Verifique sua conexão e tente novamente.',
      );
      return false;
    }
  }

  // ─── COMPLETAR KYC & ATIVAR TRIAL (GOOGLE ONBOARDING) ─────────────────────

  /// Completa o KYC obrigatório (ex: pós-Google) e ativa o Trial blindado.
  Future<bool> completeKycAndActivateTrial({
    required String cpf,
    required String phone,
    String? vehicleType,
    String? rg,
    String? billingAddress,
    String? billingCep,
  }) async {
    state = state.copyWith(isLoading: true, errorMessage: null);
    HapticFeedback.lightImpact();

    try {
      final cleanCpf = cpf.replaceAll(RegExp(r'\D'), '');
      if (cleanCpf.length != 11 || !CpfValidator.isValid(cleanCpf)) {
        state = state.copyWith(
          isLoading: false,
          errorMessage:
              'CPF inválido. Certifique-se de digitar um CPF válido com 11 dígitos.',
        );
        return false;
      }

      final updated = state.user.copyWith(
        cpf: cleanCpf,
        phone: phone.trim(),
        vehicleType: vehicleType ?? state.user.vehicleType,
        rg: rg ?? state.user.rg,
        billingAddress: billingAddress ?? state.user.billingAddress,
        billingCep: billingCep ?? state.user.billingCep,
      );

      // 1. Salva no Supabase (se o CPF já pertencer a outra conta, o uq_user_profiles_clean_cpf recusa)
      final remoteError = await _saveProfile(updated);
      if (remoteError != null) {
        String msg = remoteError;
        if (remoteError.contains('uq_user_profiles_clean_cpf') ||
            remoteError.contains('duplicate key') ||
            remoteError.contains('23505')) {
          msg = 'Este CPF já está cadastrado em outra conta L.I.F.O.';
        }
        state = state.copyWith(
          isLoading: false,
          errorMessage: msg,
        );
        return false;
      }

      // 2. Coleta hardware fingerprint
      final fp = await DeviceSecurityService.instance.getDeviceFingerprint();

      // 3. Tenta ativar os 30 dias de trial
      final trial = await SupabaseService.instance.startTrial(deviceFingerprint: fp);

      if (trial == null || trial['ok'] != true) {
        final reason = trial?['message'] as String? ??
            'Período de teste já utilizado neste aparelho ou CPF nos últimos 12 meses.';
        final expiredUser = updated.copyWith(
          expiresAt: DateTime.now().subtract(const Duration(hours: 1)),
          plan: 'Assinatura Necessária',
        );
        await _saveProfile(expiredUser);
        state = state.copyWith(
          user: expiredUser,
          isLoading: false,
          errorMessage: reason,
        );
        return false;
      }

      // 4. Trial concedido com sucesso
      final exp = DateTime.tryParse(trial['expires_at'] as String? ?? '') ??
          DateTime.now().add(const Duration(days: 30));
      final approvedUser = updated.copyWith(
        plan: 'Standard (Trial 30 Dias)',
        expiresAt: exp,
      );
      await _saveProfile(approvedUser);
      await _issueOfflineToken(approvedUser);

      state = state.copyWith(
        user: approvedUser,
        isLoading: false,
        successMessage: 'Cadastro validado! 30 dias de teste liberados.',
      );
      HapticFeedback.mediumImpact();
      return true;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: 'Falha ao ativar o teste. Verifique sua conexão.',
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

        final cleanCpf = (remoteProfile?.cpf ?? '').replaceAll(RegExp(r'\D'), '');
        final hasValidCpf = cleanCpf.length == 11 && CpfValidator.isValid(cleanCpf);

        String plan;
        DateTime expiresAt;

        if (subscription != null) {
          plan = SupabaseService.planDisplayName(subscription);
          expiresAt = DateTime.tryParse(subscription['expires_at'] as String? ?? '') ??
              DateTime.now().subtract(const Duration(minutes: 1));
        } else if (hasValidCpf && remoteProfile != null && remoteProfile.expiresAt.isAfter(DateTime.now())) {
          plan = remoteProfile.plan;
          expiresAt = remoteProfile.expiresAt;
        } else {
          plan = 'Pendente de Ativação';
          expiresAt = DateTime.now().subtract(const Duration(minutes: 1));
        }

        final profile = (remoteProfile ?? UserProfile(
          id: supaUser.id,
          name: supaUser.userMetadata?['full_name'] as String? ??
              email.split('@').first,
          email: email.trim().toLowerCase(),
          plan: plan,
          expiresAt: expiresAt,
          isLoggedIn: true,
          isGoogleAuth: false,
          cpf: remoteProfile?.cpf,
        )).copyWith(
          plan: plan,
          expiresAt: expiresAt,
          isLoggedIn: true,
        );

        await _saveProfile(profile);
        await _issueOfflineToken(profile);
        // Assinatura paga no servidor = já pagou 1x (vale p/ a confiança).
        try {
          final t = (subscription?['plan_type'] as String? ?? '').toLowerCase();
          if (t == 'pix_manual' || t == 'credit_card_auto') {
            await _markPaidOnce(profile.id);
          }
        } catch (_) {}
        state = state.copyWith(
          user: profile,
          isLoading: false,
          isOffline: false,
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
      final profile = result.profile!;
      await _saveProfile(profile);

      // Se já possui CPF cadastrado (ex: usuário antigo), tenta reconciliar trial
      final cleanCpf = (profile.cpf ?? '').replaceAll(RegExp(r'\D'), '');
      if (cleanCpf.length == 11) {
        try {
          final fp = await DeviceSecurityService.instance.getDeviceFingerprint();
          await SupabaseService.instance.startTrial(deviceFingerprint: fp);
        } catch (_) {}
      }
      await _issueOfflineToken(profile);
      try {
        if (profile.plan.toLowerCase().contains('ativo')) {
          await _markPaidOnce(profile.id);
        }
      } catch (_) {}
      state = state.copyWith(
        user: profile,
        isLoading: false,
        isOffline: false,
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

  // ─── RENOVAR ASSINATURA (sempre via servidor) ────────────────────────────
  // Chamado após o PIX confirmado. A expiração é calculada no servidor
  // (confirm-renewal → fn_apply_payment), que desconta a confiança aberta
  // (30d → 25d) e quita a graça. O app aplica o retorno — nunca calcula.

  /// Confirma o pagamento [paymentId] no servidor e aplica a validade
  /// oficial. Retorna true se ativado.
  Future<bool> confirmRenewalPayment({required String paymentId}) async {
    HapticFeedback.selectionClick();
    state = state.copyWith(isLoading: true, errorMessage: null);
    try {
      // Reconcilia graça provisória junto (o servidor valida e desconta).
      final provisional = await _provisionalGrantedAt(state.user.id);

      final res = await SupabaseService.instance.confirmRenewal(
        paymentId: paymentId,
        provisionalGrantedAt: provisional,
      );
      if (res == null || res['confirmed'] != true) {
        // Sem confirmação do servidor: relê o que o webhook possa ter
        // aplicado; sem avanço, erro (sem matemática local).
        final ok = await _refreshFromServer();
        state = state.copyWith(isLoading: false);
        return ok;
      }

      final exp = DateTime.tryParse(res['expires_at'] as String? ?? '');
      final planName = res['plan'] as String? ?? state.user.plan;
      final deducted = (res['deducted_days'] as num?)?.toInt() ?? 0;
      if (exp == null) {
        state = state.copyWith(
          isLoading: false,
          errorMessage: 'Pagamento confirmado, sincronizando…',
        );
        await _refreshFromServer();
        return true;
      }

      final updated = state.user.copyWith(expiresAt: exp, plan: planName);
      await _saveProfileLocal(updated);
      await _markPaidOnce(updated.id);
      await _clearGraceMirror(updated.id);
      await _issueOfflineToken(updated);
      state = state.copyWith(
        user: updated,
        isLoading: false,
        isOffline: false,
        graceOfferPending: false,
        successMessage: deducted > 0
            ? 'Pagamento confirmado! Confiança de $deducted dias descontada. Bom trabalho.'
            : 'Assinatura renovada com sucesso! Bom trabalho.',
      );
      HapticFeedback.mediumImpact();
      return true;
    } catch (_) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: 'Falha ao confirmar. Verifique sua internet.',
      );
      return false;
    }
  }

  /// Relê perfil+assinatura do servidor e espelha local. True se a validade
  /// avançou além do estado atual (webhook pode ter aplicado).
  Future<bool> _refreshFromServer() async {
    try {
      final before = state.user.expiresAt;
      final remote = await SupabaseService.instance.fetchUserProfile();
      if (remote == null) return false;
      var merged = remote.copyWith(isLoggedIn: true);
      try {
        final sub = await SupabaseService.instance.fetchSubscription();
        if (sub != null) {
          merged = merged.copyWith(
            plan: SupabaseService.planDisplayName(sub),
            expiresAt: DateTime.tryParse(sub['expires_at'] as String? ?? '') ??
                remote.expiresAt,
          );
          final t = (sub['plan_type'] as String? ?? '').toLowerCase();
          if (t == 'pix_manual' || t == 'credit_card_auto') {
            await _markPaidOnce(merged.id);
          }
        }
      } catch (_) {}
      await _saveProfileLocal(merged);
      await _issueOfflineToken(merged);
      final advanced = merged.expiresAt.isAfter(before);
      if (advanced) {
        await _clearGraceMirror(merged.id);
        state = state.copyWith(
          user: merged,
          isOffline: false,
          graceOfferPending: false,
          successMessage: 'Assinatura sincronizada com o servidor!',
        );
      }
      return advanced;
    } catch (_) {
      return false;
    }
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
    final cleanCpf = (cpf ?? state.user.cpf ?? '').replaceAll(RegExp(r'\D'), '');
    final updated = state.user.copyWith(
      name: name,
      email: email,
      cpf: cleanCpf.isNotEmpty ? cleanCpf : cpf,
      rg: rg,
      phone: phone,
      billingAddress: billingAddress,
      billingCep: billingCep,
      cityUf: cityUf,
    );
    final remoteError = await _saveProfile(updated);
    if (remoteError != null) {
      String msg = remoteError;
      if (remoteError.contains('uq_user_profiles_clean_cpf') ||
          remoteError.contains('duplicate key') ||
          remoteError.contains('23505')) {
        msg = 'Este CPF já está cadastrado em outra conta L.I.F.O.';
      }
      state = state.copyWith(
        user: updated,
        errorMessage: 'Salvo no aparelho, mas o servidor recusou: $msg',
        successMessage: null,
      );
      return false;
    }

    // Se o usuário está pendente de ativação ou expirado e forneceu CPF válido de 11 dígitos:
    // ATIVA OS 30 DIAS DE TESTE GRÁTIS IMEDIATAMENTE!
    final isPendingTrial = state.user.plan.toLowerCase().contains('pendente') ||
        !state.user.expiresAt.isAfter(DateTime.now());

    if (cleanCpf.length == 11 &&
        CpfValidator.isValid(cleanCpf) &&
        isPendingTrial) {
      try {
        final fp = await DeviceSecurityService.instance.getDeviceFingerprint();
        final trial = await SupabaseService.instance.startTrial(deviceFingerprint: fp);
        if (trial != null && trial['ok'] == true) {
          final exp = DateTime.tryParse(trial['expires_at'] as String? ?? '') ??
              DateTime.now().add(const Duration(days: 30));
          final approvedUser = updated.copyWith(
            plan: 'Standard (Trial 30 Dias)',
            expiresAt: exp,
          );
          await _saveProfile(approvedUser);
          await _issueOfflineToken(approvedUser);
          state = state.copyWith(
            user: approvedUser,
            successMessage: 'Dados salvos! Teste grátis de 30 dias liberado.',
            errorMessage: null,
          );
          return true;
        } else if (trial != null && trial['ok'] == false) {
          final trialMsg = trial['message'] as String? ??
              'Período de teste já utilizado neste CPF ou aparelho nos últimos 12 meses.';
          state = state.copyWith(
            user: updated,
            errorMessage: trialMsg,
            successMessage: null,
          );
          return false;
        }
      } catch (_) {}
    }

    state = state.copyWith(
      user: updated,
      successMessage: 'Perfil atualizado no banco de dados!',
      errorMessage: null,
    );
    return true;
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

    // Limpa 100% da sessão local: SQLite + prefs + token offline. Sem espelho, sem fantasma.
    try {
      await AppDatabase.instance.clearUserProfile();
    } catch (_) {}
    try {
      await OfflineLicenseGuard.clearLicenseToken();
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
      isOffline: false,
      successMessage: null,
      errorMessage: null,
    );
  }
}

final authControllerProvider =
    StateNotifierProvider<AuthController, AuthState>((ref) {
  return AuthController();
});
