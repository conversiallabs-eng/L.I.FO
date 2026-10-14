import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../domain/models/user_profile.dart';
import '../../../../core/network/supabase_service.dart';

class AsaasPixChargeResponse {
  final String paymentId;
  final String copyAndPastePix;
  final String? qrCodeBase64;
  final double value;
  final DateTime expirationDate;
  final String status;

  const AsaasPixChargeResponse({
    required this.paymentId,
    required this.copyAndPastePix,
    this.qrCodeBase64,
    required this.value,
    required this.expirationDate,
    required this.status,
  });

  factory AsaasPixChargeResponse.fromJson(Map<String, dynamic> json) {
    return AsaasPixChargeResponse(
      paymentId: json['payment_id'] as String? ?? json['id'] as String? ?? 'pay_${DateTime.now().millisecondsSinceEpoch}',
      copyAndPastePix: json['copy_and_paste_pix'] as String? ?? json['pixCopiaECola'] as String? ?? json['payload'] as String? ?? '',
      qrCodeBase64: json['qr_code_base64'] as String? ?? json['encodedImage'] as String?,
      value: (json['value'] as num?)?.toDouble() ?? 19.90,
      expirationDate: DateTime.tryParse(json['expiration_date'] as String? ?? json['expirationDate'] as String? ?? '') ??
          DateTime.now().add(const Duration(hours: 24)),
      status: json['status'] as String? ?? 'PENDING',
    );
  }
}

class AsaasPaymentService {
  static final AsaasPaymentService instance = AsaasPaymentService._internal();
  AsaasPaymentService._internal();

  /// URL padrão da API do Asaas ou Supabase Edge Function para cobranças PIX
  static const String _kSupabaseEdgeFunctionUrl = 'https://sjbmweuszwxbkdimbwdg.supabase.co/functions/v1/create-asaas-pix-charge';

  /// Cria uma cobrança PIX no valor de R$ 19,90 via Asaas / Supabase
  /// Lança [Exception] com a mensagem real do Asaas em caso de falha
  /// (sem fallback falso: PIX falso faz o usuário pagar e não liberar).
  Future<AsaasPixChargeResponse> createPixCharge({
    required UserProfile user,
    double amount = 19.90,
  }) async {
    final cpfDigits = (user.cpf ?? '').replaceAll(RegExp(r'\D'), '');
    if (cpfDigits.length != 11 && cpfDigits.length != 14) {
      throw Exception(
        'CPF/CNPJ inválido. Atualize seu CPF em Minha Conta antes de gerar o PIX.',
      );
    }

    final payload = {
      'user_id': user.id,
      'customer_name': user.name.isNotEmpty ? user.name : 'Cliente LIFO',
      'customer_email': user.email,
      'customer_cpf': cpfDigits,
      'value': amount,
      'description': 'Assinatura LIFO Pro - 30 Dias',
    };

    String? lastError;
    try {
      // 1. Tenta chamar Supabase Edge Function se inicializado
      if (SupabaseService.instance.isInitialized) {
        try {
          final res = await Supabase.instance.client.functions.invoke(
            'create-asaas-pix-charge',
            body: payload,
          );
          if (res.status == 200 && res.data != null) {
            final data = res.data is String ? jsonDecode(res.data) : res.data;
            final map = data as Map<String, dynamic>;
            if (map['error'] != null) {
              lastError = map['error'] as String?;
            } else {
              return AsaasPixChargeResponse.fromJson(map);
            }
          } else {
            final data = res.data is String
                ? jsonDecode(res.data)
                : res.data;
            lastError = (data is Map ? data['error'] as String? : null) ??
                'Asaas recusou a cobrança (HTTP ${res.status}).';
          }
        } catch (e) {
          lastError = '$e';
          debugPrint('Supabase Edge Function Asaas falhou: $e');
        }
      } else {
        lastError = 'Sem conexão com o servidor. Tente novamente.';
      }

      // 2. Tenta HTTP POST direto caso a Edge Function esteja rodando como endpoint genérico
      if (lastError != null) {
        try {
          final httpRes = await http.post(
            Uri.parse(_kSupabaseEdgeFunctionUrl),
            headers: {
              'Content-Type': 'application/json',
              if (SupabaseService.instance.isInitialized)
                'Authorization':
                    'Bearer ${Supabase.instance.client.auth.currentSession?.accessToken ?? ""}',
            },
            body: jsonEncode(payload),
          ).timeout(const Duration(seconds: 8));

          if (httpRes.statusCode == 200) {
            final data = jsonDecode(httpRes.body) as Map<String, dynamic>;
            if (data['error'] == null) {
              return AsaasPixChargeResponse.fromJson(data);
            }
            lastError = data['error'] as String?;
          } else {
            lastError =
                'Asaas recusou a cobrança (HTTP ${httpRes.statusCode}).';
          }
        } catch (e) {
          debugPrint('Erro de conexão com API Asaas: $e.');
        }
      }
    } catch (e) {
      lastError = '$e';
    }

    throw Exception(lastError ?? 'Não foi possível gerar a cobrança PIX.');
  }

  /// Consulta o status da cobrança PIX no Asaas
  Future<bool> checkPaymentStatus({required String paymentId}) async {
    try {
      if (SupabaseService.instance.isInitialized) {
        final res = await Supabase.instance.client.functions.invoke(
          'check-asaas-payment',
          body: {'payment_id': paymentId},
        );
        if (res.status == 200 && res.data != null) {
          final data = res.data is String ? jsonDecode(res.data) : res.data;
          final status = (data['status'] as String? ?? '').toUpperCase();
          return status == 'RECEIVED' || status == 'CONFIRMED' || status == 'RECEIVED_IN_CASH';
        }
      }
    } catch (_) {}
    return false;
  }
}
