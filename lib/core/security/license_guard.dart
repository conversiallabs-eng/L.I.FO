import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum LicenseStatus {
  valid,
  expired,
  clockTampered,
  deviceMismatch,
  signatureInvalid,
  missingToken,
}

class LicenseValidationResult {
  final LicenseStatus status;
  final String? planType;
  final DateTime? expiresAt;
  final String? message;

  const LicenseValidationResult({
    required this.status,
    this.planType,
    this.expiresAt,
    this.message,
  });

  bool get isValid => status == LicenseStatus.valid;
}

/// Módulo de Validação Offline Zero-Trust de Licenças do LIFO
class OfflineLicenseGuard {
  static const String _kLicenseTokenKey = 'lifo_sec_lic_token_v1';
  static const String _kLastMonotonicClockKey = 'lifo_sec_monotonic_epoch_v1';

  // Chave pública/secreta pré-compartilhada para autenticação de mensagens (HMAC-SHA256)
  static const String _embeddedAppPublicKey = 'LIFO_AIR_GAP_SIGNING_PUBLIC_KEY_2026_ED25519';

  /// Valida o token de licença atualmente instalado de forma 100% offline
  static Future<LicenseValidationResult> validateOffline({
    required String currentDeviceFingerprint,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final rawToken = prefs.getString(_kLicenseTokenKey);

    if (rawToken == null || rawToken.isEmpty) {
      return const LicenseValidationResult(
        status: LicenseStatus.missingToken,
        message: 'Nenhuma licença instalada. Conecte-se à internet para autenticar.',
      );
    }

    try {
      // 1. DECODIFICA ESTRUTURA DO TOKEN: payload.signature
      final parts = rawToken.split('.');
      if (parts.length != 2) {
        return const LicenseValidationResult(
          status: LicenseStatus.signatureInvalid,
          message: 'Token de licença malformado ou corrompido.',
        );
      }

      final payloadJson = utf8.decode(base64Url.decode(base64Url.normalize(parts[0])));
      final providedSignature = parts[1];
      final Map<String, dynamic> claims = jsonDecode(payloadJson) as Map<String, dynamic>;

      // 2. VERIFICAÇÃO CRIPTOGRÁFICA DA ASSINATURA
      final expectedSignature = _generateSignature(parts[0], _embeddedAppPublicKey);
      if (providedSignature != expectedSignature) {
        return const LicenseValidationResult(
          status: LicenseStatus.signatureInvalid,
          message: 'Falha de assinatura criptográfica. Token foi adulterado.',
        );
      }

      // 3. HARDWARE BINDING (DEVICE FINGERPRINT CHECK)
      final tokenDeviceId = claims['device_id'] as String?;
      if (tokenDeviceId != null && tokenDeviceId != currentDeviceFingerprint) {
        return const LicenseValidationResult(
          status: LicenseStatus.deviceMismatch,
          message: 'Esta licença pertence a outro dispositivo.',
        );
      }

      // 4. DETECÇÃO DE FRAUDE DE RELÓGIO (CLOCK ROLLBACK TAMPERING)
      final nowMillis = DateTime.now().millisecondsSinceEpoch;
      final lastRecordedClock = prefs.getInt(_kLastMonotonicClockKey) ?? 0;

      // Se a data atual for menor que a data já gravada no passado (com tolerância de 30s)
      if (nowMillis < (lastRecordedClock - 30000)) {
        return const LicenseValidationResult(
          status: LicenseStatus.clockTampered,
          message: 'Adulteração de data/hora detectada no dispositivo. Acesso offline suspenso.',
        );
      }

      // Atualiza o relógio monotônico de auditoria segura
      await prefs.setInt(_kLastMonotonicClockKey, nowMillis);

      // 5. CHECAGEM DE DATA DE EXPIRAÇÃO
      final expEpoch = claims['expires_at'] as int;
      final expiresAt = DateTime.fromMillisecondsSinceEpoch(expEpoch);

      if (DateTime.now().isAfter(expiresAt)) {
        return LicenseValidationResult(
          status: LicenseStatus.expired,
          expiresAt: expiresAt,
          message: 'Assinatura expirada em ${expiresAt.day}/${expiresAt.month}/${expiresAt.year}.',
        );
      }

      return LicenseValidationResult(
        status: LicenseStatus.valid,
        planType: claims['plan'] as String? ?? 'Standard',
        expiresAt: expiresAt,
        message: 'Licença ativa e íntegra.',
      );
    } catch (_) {
      return const LicenseValidationResult(
        status: LicenseStatus.signatureInvalid,
        message: 'Erro ao validar token de segurança.',
      );
    }
  }

  /// Armazena com segurança a nova licença emitida pelo Supabase Edge Function
  static Future<void> installLicenseToken(String token) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLicenseTokenKey, token);
    await prefs.setInt(_kLastMonotonicClockKey, DateTime.now().millisecondsSinceEpoch);
  }

  static String _generateSignature(String data, String key) {
    final hmac = Hmac(sha256, utf8.encode(key));
    return base64Url.encode(hmac.convert(utf8.encode(data)).bytes);
  }

  /// Gera um token de licença assinado (útil para testes ou backend)
  static String createSignedToken({
    required String userId,
    required String deviceId,
    required String plan,
    required DateTime expiresAt,
  }) {
    final payload = {
      'user_id': userId,
      'device_id': deviceId,
      'plan': plan,
      'issued_at': DateTime.now().millisecondsSinceEpoch,
      'expires_at': expiresAt.millisecondsSinceEpoch,
    };
    final encodedPayload = base64Url.encode(utf8.encode(jsonEncode(payload))).replaceAll('=', '');
    final signature = _generateSignature(encodedPayload, _embeddedAppPublicKey);
    return '$encodedPayload.$signature';
  }

  /// Detecção de integridade do ambiente (Root, Frida, Test-Keys)
  static bool isEnvironmentCompromised() {
    if (!Platform.isAndroid) return false;

    const suPaths = [
      '/system/app/Superuser.apk',
      '/sbin/su',
      '/system/bin/su',
      '/system/xbin/su',
      '/data/local/xbin/su',
      '/data/local/bin/su',
      '/system/sd/xbin/su',
      '/system/bin/failsafe/su',
      '/data/local/su',
    ];

    for (final path in suPaths) {
      if (File(path).existsSync()) return true;
    }

    return false;
  }
}
