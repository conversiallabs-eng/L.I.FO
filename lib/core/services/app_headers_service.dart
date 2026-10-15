import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// Headers de identificação do app p/ provedores de mapa (Fase trava CARTO).
///
/// A trava de mobile app da CARTO cobra `X-Android-Package` + `X-Android-Cert`
/// (SHA-1 da assinatura) no Android e `X-Ios-Bundle-Identifier` no iOS.
/// Sem eles, o tile volta 403 e o mapa apaga — mesmo com key válida.
/// O User-Agent vai junto em tudo.
class AppHeadersService {
  static final AppHeadersService instance = AppHeadersService._internal();
  AppHeadersService._internal();

  static const MethodChannel _channel =
      MethodChannel('com.lifo.app/attestation');

  static const String userAgent = 'LifoApp/1.0 (com.lifo.app)';

  Map<String, String>? _cached;

  /// Mapa pronto p/ Dio/http. Cacheado após a 1ª montagem; nunca lança.
  Future<Map<String, String>> tileHeaders() async {
    final hit = _cached;
    if (hit != null) return Map.of(hit);
    final headers = <String, String>{'User-Agent': userAgent};
    try {
      final info = await PackageInfo.fromPlatform()
          .timeout(const Duration(seconds: 3));
      final package = info.packageName;
      if (Platform.isAndroid) {
        if (package.isNotEmpty) {
          headers['X-Android-Package'] = package;
        }
        final cert = await _androidCertSha1();
        if (cert != null && cert.isNotEmpty) {
          headers['X-Android-Cert'] = cert;
        }
      } else if (Platform.isIOS || Platform.isMacOS) {
        if (package.isNotEmpty) {
          headers['X-Ios-Bundle-Identifier'] = package;
        }
      }
    } catch (_) {}
    _cached = Map.of(headers);
    return Map.of(headers);
  }

  /// Versão síncrona (último valor conhecido ou só User-Agent).
  Map<String, String> get tileHeadersSync {
    final hit = _cached;
    if (hit != null) return Map.of(hit);
    return {'User-Agent': userAgent};
  }

  Future<String?> _androidCertSha1() async {
    try {
      final cert = await _channel
          .invokeMethod<String>('getSigningCertSha1')
          .timeout(const Duration(seconds: 3));
      return (cert == null || cert.isEmpty) ? null : cert;
    } catch (_) {
      return null;
    }
  }

  /// Formata bytes de certificado em "AA:BB:..." (pura, testável).
  static String formatCertSha1(List<int> bytes) {
    const hex = '0123456789ABCDEF';
    final sb = StringBuffer();
    for (var i = 0; i < bytes.length; i++) {
      if (i > 0) sb.write(':');
      final b = bytes[i] & 0xFF;
      sb.write(hex[(b >> 4) & 0xF]);
      sb.write(hex[b & 0xF]);
    }
    return sb.toString();
  }

  /// Só p/ testes: limpa o cache.
  @visibleForTesting
  void debugReset() => _cached = null;
}
