import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Endereço resolvido via BrasilAPI (gratuita, sem chave).
class CepAddress {
  final String street;
  final String neighborhood;
  final String city;
  final String state;

  const CepAddress({
    required this.street,
    required this.neighborhood,
    required this.city,
    required this.state,
  });

  /// "Rua X, Bairro Y" (pula partes vazias).
  String get shortAddress {
    final parts = [
      street.trim(),
      neighborhood.trim(),
    ].where((p) => p.isNotEmpty).toList();
    return parts.join(', ');
  }

  /// "Florianópolis - SC".
  String get cityUf {
    if (city.isEmpty) return state;
    if (state.isEmpty) return city;
    return '$city - $state';
  }

  bool get hasAny =>
      street.isNotEmpty || neighborhood.isNotEmpty || city.isNotEmpty;
}

class CepService {
  static final CepService instance = CepService._internal();
  CepService._internal();

  /// Busca o endereço do [cep] (só dígitos). Retorna null se inválido,
  /// não encontrado ou sem internet. Nunca lança.
  Future<CepAddress?> fetchAddress(String cep) async {
    final digits = cep.replaceAll(RegExp(r'\D'), '');
    if (digits.length != 8) return null;
    try {
      final res = await http
          .get(Uri.parse('https://brasilapi.com.br/api/cep/v1/$digits'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) return null;
      final map = jsonDecode(res.body) as Map<String, dynamic>;
      final addr = CepAddress(
        street: (map['street'] as String? ?? '').trim(),
        neighborhood: (map['neighborhood'] as String? ?? '').trim(),
        city: (map['city'] as String? ?? '').trim(),
        state: (map['state'] as String? ?? '').trim(),
      );
      if (!addr.hasAny) return null;
      return addr;
    } catch (e) {
      debugPrint('CepService falhou: $e');
      return null;
    }
  }
}
