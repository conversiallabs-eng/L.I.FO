import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'supabase_service.dart';
import '../../features/auth/presentation/controllers/auth_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Observa a rede e drena o que ficou pendente offline.
///
/// - Ao reconectar: `processSyncQueue()` (fila nunca drenada antes),
///   `revalidateWhenOnline()` (sai do modo offline sem trocar de tela).
/// - Expõe [isOnlineNow] para a UI desabilitar busca/geocode/otimização
///   viária com mensagem clara em vez de falhar silencioso.
class ConnectivityService {
  static final ConnectivityService instance =
      ConnectivityService._internal();
  ConnectivityService._internal();

  final Connectivity _connectivity = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _sub;
  ProviderContainer? _container;

  final ValueNotifier<bool> isOnline = ValueNotifier<bool>(true);
  bool _lastOnline = true;

  void attach(ProviderContainer container) {
    _container = container;
    _sub?.cancel();
    _sub = _connectivity.onConnectivityChanged.listen(_onChanged);
    // Checagem inicial (não bloqueia).
    _connectivity.checkConnectivity().then((results) {
      final online = _isOnlineResults(results);
      _lastOnline = online;
      isOnline.value = online;
    }).catchError((_) {});
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
    _container = null;
  }

  bool _isOnlineResults(List<ConnectivityResult> results) {
    if (results.isEmpty) return false;
    return results.any((r) =>
        r == ConnectivityResult.mobile ||
        r == ConnectivityResult.wifi ||
        r == ConnectivityResult.ethernet ||
        r == ConnectivityResult.vpn);
  }

  Future<void> _onChanged(List<ConnectivityResult> results) async {
    final online = _isOnlineResults(results);
    final wasOffline = !_lastOnline && online;
    _lastOnline = online;
    isOnline.value = online;
    if (!wasOffline) return;

    debugPrint('Connectivity: voltou online, drenando pendências…');
    try {
      final drained = await SupabaseService.instance.processSyncQueue();
      if (drained > 0) debugPrint('Connectivity: $drained itens sincronizados.');
    } catch (_) {}
    try {
      await _container
          ?.read(authControllerProvider.notifier)
          .revalidateWhenOnline();
    } catch (_) {}
  }

  /// Checagem pontual (para o boot e para o botão "tentar de novo").
  Future<bool> checkNow() async {
    try {
      final results = await _connectivity
          .checkConnectivity()
          .timeout(const Duration(seconds: 4));
      final online = _isOnlineResults(results);
      _lastOnline = online;
      isOnline.value = online;
      return online;
    } catch (_) {
      return isOnline.value;
    }
  }
}
