import 'package:flutter/material.dart';
import '../../features/auth/domain/models/user_profile.dart';
import '../../features/auth/presentation/screens/subscription_renewal_screen.dart';

class NotificationService {
  static final NotificationService instance = NotificationService._internal();
  NotificationService._internal();

  String? _fcmToken;
  bool _hasNotifiedThisSession = false;

  /// FCM Token atual registrado no aplicativo
  String? get fcmToken => _fcmToken;

  /// Registra ou atualiza o token do Firebase Cloud Messaging (FCM)
  void setFcmToken(String token) {
    _fcmToken = token;
  }

  /// Verifica se a assinatura está a 1 dia do vencimento e exibe aviso em tela
  void checkExpiryAndNotify(BuildContext context, UserProfile user) {
    if (_hasNotifiedThisSession) return;
    if (!user.isLoggedIn) return;

    final now = DateTime.now();
    final expiresAt = user.expiresAt;

    // Se a assinatura expira dentro das próximas 24 horas (1 dia antes do vencimento)
    final hoursRemaining = expiresAt.difference(now).inHours;
    final isAboutToExpireInOneDay = hoursRemaining >= 0 && hoursRemaining <= 24;

    if (isAboutToExpireInOneDay) {
      _hasNotifiedThisSession = true;

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;

        showDialog(
          context: context,
          builder: (dCtx) {
            final isDark = Theme.of(dCtx).brightness == Brightness.dark;
            return AlertDialog(
              backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              title: const Row(
                children: [
                  Icon(Icons.warning_amber_rounded,
                      color: Color(0xFFF59E0B), size: 28),
                  SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Assinatura Vencendo',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
              content: Text(
                'Sua assinatura LIFO Pro expira amanhã. Renove agora por R\$ 19,90 via PIX para não perder o acesso às suas rotas e mapas.',
                style: TextStyle(
                  fontSize: 13.5,
                  color: isDark ? const Color(0xFFCBD5E1) : const Color(0xFF475569),
                  height: 1.4,
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dCtx),
                  child: const Text('Lembrar Depois'),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2563EB),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onPressed: () {
                    Navigator.pop(dCtx);
                    SubscriptionRenewalScreen.open(context);
                  },
                  child: const Text('Renovar Agora'),
                ),
              ],
            );
          },
        );
      });
    }
  }
}
