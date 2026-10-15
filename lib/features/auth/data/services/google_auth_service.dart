import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../domain/models/user_profile.dart';
import '../../../../core/network/supabase_service.dart';

/// Resultado do processo de Google Sign-In
class GoogleSignInResult {
  final bool success;
  final UserProfile? profile;
  final String? errorMessage;

  const GoogleSignInResult({
    required this.success,
    this.profile,
    this.errorMessage,
  });
}

class GoogleAuthService {
  static final GoogleAuthService instance = GoogleAuthService._internal();
  GoogleAuthService._internal();

  bool _initialized = false;

  // Web Client ID gerado no Google Cloud Console para o projeto LIFO.
  // IMPORTANTE: Este ID deve ser o "Web application" Client ID (não o Android),
  // pois é ele que o Supabase usa para validar o idToken.
  // Configure em: https://console.cloud.google.com/apis/credentials
  // e cole aqui após criar as credenciais OAuth 2.0.
  static const String _serverClientId =
      '449346510869-lqu91hbsc6v7uhagpgggb5f29cc8kua7.apps.googleusercontent.com';

  /// Inicializa o GoogleSignIn (deve ser chamado 1x antes de autenticar)
  Future<void> initialize() async {
    if (_initialized) return;
    await GoogleSignIn.instance.initialize(
      serverClientId: _serverClientId,
    );
    _initialized = true;
  }

  /// Executa o fluxo nativo de Google Sign-In e autentica no Supabase.
  Future<GoogleSignInResult> signIn() async {
    try {
      await initialize();

      // 1. Abre o seletor de conta do Google (authenticate = fluxo interativo)
      final googleAccount = await GoogleSignIn.instance.authenticate();

      // 2. Obtém o idToken da autenticação
      final idToken = googleAccount.authentication.idToken;

      if (idToken == null) {
        return const GoogleSignInResult(
          success: false,
          errorMessage: 'Não foi possível obter o token do Google.',
        );
      }

      // 3. Autentica no Supabase com o idToken do Google
      final supabase = Supabase.instance.client;
      final response = await supabase.auth.signInWithIdToken(
        provider: OAuthProvider.google,
        idToken: idToken,
      );

      final supaUser = response.user;
      if (supaUser == null) {
        return const GoogleSignInResult(
          success: false,
          errorMessage: 'Falha na autenticação com Supabase.',
        );
      }

      // 4. Busca perfil remoto ou cria novo com dados do Google
      final remoteProfile = await SupabaseService.instance.fetchUserProfile();

      final profile = remoteProfile ??
          UserProfile(
            id: supaUser.id,
            name: googleAccount.displayName ??
                googleAccount.email.split('@').first,
            email: googleAccount.email,
            plan: 'Standard (Trial 30 Dias)',
            expiresAt: DateTime.now().add(const Duration(days: 30)),
            isLoggedIn: true,
            isGoogleAuth: true,
            avatarUrl: googleAccount.photoUrl,
          );

      // Se é o primeiro login, salva os dados do perfil. O trial é criado
      // pelo controller via fn_start_trial (server-side, trial único).
      if (remoteProfile == null) {
        await SupabaseService.instance.upsertUserProfile(
          profile.copyWith(isLoggedIn: true, isGoogleAuth: true),
        );
      }

      return GoogleSignInResult(
        success: true,
        profile: profile.copyWith(isLoggedIn: true, isGoogleAuth: true),
      );
    } on GoogleSignInException catch (e) {
      // Usuário cancelou ou erro específico do Google
      if (e.code == GoogleSignInExceptionCode.canceled) {
        return const GoogleSignInResult(
          success: false,
          errorMessage: 'Login cancelado pelo usuário.',
        );
      }
      return GoogleSignInResult(
        success: false,
        errorMessage: 'Erro Google Sign-In: ${e.code.name}',
      );
    } catch (e) {
      return GoogleSignInResult(
        success: false,
        errorMessage: 'Erro ao conectar com Google: ${e.toString()}',
      );
    }
  }

  /// Faz logout do Google e do Supabase
  Future<void> signOut() async {
    try {
      await GoogleSignIn.instance.signOut();
    } catch (_) {}
  }
}
