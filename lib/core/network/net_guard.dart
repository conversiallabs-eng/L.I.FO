import 'package:connectivity_plus/connectivity_plus.dart';

/// Checagem rápida de rede (<2s) para fast-path offline.
///
/// Sem conectividade, o app pula direto para o cache local (auth, geometria
/// de rua salva) em vez de queimar timeouts de 10-15s por tentativa OSRM —
/// era isso que prendia o boot e a abertura da rota sem internet.
Future<bool> isOfflineFast() async {
  try {
    final results = await Connectivity()
        .checkConnectivity()
        .timeout(const Duration(seconds: 2));
    if (results.isEmpty) return true;
    return results.every((r) =>
        r == ConnectivityResult.none ||
        r == ConnectivityResult.bluetooth);
  } catch (_) {
    return false;
  }
}
