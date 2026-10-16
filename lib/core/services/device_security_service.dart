import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// Serviço de segurança de hardware para proteção contra rodízio de contas
/// e abuso de período de teste gratuito (anti-trial-farming).
class DeviceSecurityService {
  DeviceSecurityService._();
  static final DeviceSecurityService instance = DeviceSecurityService._();

  static const String _kDeviceFpKey = 'lifo_device_hardware_fingerprint_v1';
  final DeviceInfoPlugin _deviceInfo = DeviceInfoPlugin();

  String? _cachedFingerprint;

  /// Retorna um hash único e persistente do dispositivo físico.
  Future<String> getDeviceFingerprint() async {
    if (_cachedFingerprint != null && _cachedFingerprint!.isNotEmpty) {
      return _cachedFingerprint!;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final savedFp = prefs.getString(_kDeviceFpKey);
      if (savedFp != null && savedFp.isNotEmpty) {
        _cachedFingerprint = savedFp;
        return savedFp;
      }

      final rawHardwareData = await _collectHardwareIdentifiers();
      
      // Gera hash SHA-256 estável dos identificadores
      final bytes = utf8.encode(rawHardwareData);
      final digest = sha256.convert(bytes);
      final fingerprint = 'fp_${digest.toString().substring(0, 32)}';

      await prefs.setString(_kDeviceFpKey, fingerprint);
      _cachedFingerprint = fingerprint;
      return fingerprint;
    } catch (e) {
      debugPrint('DeviceSecurityService error: $e');
      // Fallback resiliente caso haja erro de permissão
      final prefs = await SharedPreferences.getInstance();
      var fallback = prefs.getString(_kDeviceFpKey);
      if (fallback == null || fallback.isEmpty) {
        fallback = 'fallback_${const Uuid().v4().replaceAll('-', '').substring(0, 24)}';
        await prefs.setString(_kDeviceFpKey, fallback);
      }
      _cachedFingerprint = fallback;
      return fallback;
    }
  }

  Future<String> _collectHardwareIdentifiers() async {
    final buffer = StringBuffer();

    if (kIsWeb) {
      final web = await _deviceInfo.webBrowserInfo;
      buffer.write('web|${web.browserName}|${web.platform}|${web.userAgent}');
      return buffer.toString();
    }

    if (Platform.isAndroid) {
      final android = await _deviceInfo.androidInfo;
      buffer.write('android|');
      buffer.write('${android.id}|');
      buffer.write('${android.fingerprint}|');
      buffer.write('${android.hardware}|');
      buffer.write('${android.manufacturer}|');
      buffer.write('${android.model}|');
      buffer.write('${android.brand}|');
      buffer.write(android.board);
      return buffer.toString();
    }

    if (Platform.isIOS) {
      final ios = await _deviceInfo.iosInfo;
      buffer.write('ios|');
      buffer.write('${ios.identifierForVendor}|');
      buffer.write('${ios.model}|');
      buffer.write('${ios.name}|');
      buffer.write(ios.systemVersion);
      return buffer.toString();
    }

    if (Platform.isWindows) {
      final win = await _deviceInfo.windowsInfo;
      buffer.write('win|${win.deviceId}|${win.computerName}|${win.numberOfCores}');
      return buffer.toString();
    }

    // Outros sistemas
    buffer.write('generic|${Platform.operatingSystem}|${Platform.numberOfProcessors}');
    return buffer.toString();
  }
}
