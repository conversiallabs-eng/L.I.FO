import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../domain/models/user_profile.dart';
import '../../../../core/network/supabase_service.dart';
import '../../../../core/utils/cpf_validator.dart';

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
    // ── Fonte da verdade: repuxa o perfil fresco do Supabase ──────────────
    // Evita cobrar com CPF/nome/e-mail velhos do cache local.
    UserProfile effective = user;
    try {
      final fresh = await SupabaseService.instance.fetchUserProfile();
      if (fresh != null) {
        effective = fresh.copyWith(isLoggedIn: true);
        debugPrint(
          'Asaas: perfil fresco do Supa — nome="${effective.name}" '
          'email="${effective.email}" cpf=${_maskDoc(effective.cpf)}',
        );
      } else {
        debugPrint('Asaas: sem perfil no Supa, usando cache local.');
      }
    } catch (e) {
      debugPrint('Asaas: falha ao repuxar perfil do Supa: $e');
    }

    final cpfDigits = (effective.cpf ?? '').replaceAll(RegExp(r'\D'), '');
    if (cpfDigits.length != 11 && cpfDigits.length != 14) {
      throw Exception(
        'CPF/CNPJ inválido. Atualize seu CPF em Minha Conta antes de gerar o PIX.',
      );
    }
    // O Asaas valida o dígito verificador em produção: barra antes do 400.
    if (cpfDigits.length == 11 && !CpfValidator.isValid(cpfDigits)) {
      throw Exception(
        'CPF inválido (dígito verificador não confere). Confira em Minha Conta — o Asaas recusa CPF falso com erro 400.',
      );
    }
    if (effective.name.trim().length < 3) {
      throw Exception(
        'Nome incompleto no cadastro. Atualize seu nome em Minha Conta.',
      );
    }
    if (!effective.email.contains('@') || !effective.email.contains('.')) {
      throw Exception(
        'E-mail inválido no cadastro. Atualize em Minha Conta.',
      );
    }

    final payload = {
      'user_id': effective.id,
      'customer_name': effective.name.trim(),
      'customer_email': effective.email.trim().toLowerCase(),
      'customer_cpf': cpfDigits,
      if ((effective.phone ?? '').trim().isNotEmpty)
        'customer_phone': effective.phone!.replaceAll(RegExp(r'\D'), ''),
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
          // functions.invoke lança exceção em HTTP != 2xx; o corpo do erro
          // (com o motivo real do Asaas) vem em details.
          lastError = _extractFunctionError(e);
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
              'apikey': Supabase.instance.client.auth.currentSession?.accessToken ?? '',
              if (SupabaseService.instance.isInitialized)
                'Authorization':
                    'Bearer ${Supabase.instance.client.auth.currentSession?.accessToken ?? ""}',
            },
            body: jsonEncode(payload),
          ).timeout(const Duration(seconds: 12));

          if (httpRes.statusCode == 200) {
            final data = jsonDecode(httpRes.body) as Map<String, dynamic>;
            if (data['error'] == null) {
              return AsaasPixChargeResponse.fromJson(data);
            }
            lastError = data['error'] as String?;
          } else {
            // Extrai o motivo real do corpo em vez de engolir com "HTTP 400".
            final detail = _extractHttpBodyError(httpRes.body);
            debugPrint(
              'Asaas fallback HTTP ${httpRes.statusCode}: ${httpRes.body.substring(0, httpRes.body.length.clamp(0, 400))}',
            );
            lastError = detail ??
                '$lastError (fallback HTTP ${httpRes.statusCode})';
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

  /// Mascara CPF/CNPJ p/ log (mostra só os 2 últimos dígitos).
  String _maskDoc(String? doc) {
    final d = (doc ?? '').replaceAll(RegExp(r'\D'), '');
    if (d.isEmpty) return '(vazio)';
    if (d.length <= 2) return '*' * d.length;
    return '${'*' * (d.length - 2)}${d.substring(d.length - 2)}';
  }

  /// Tenta ler {"error": "..."} do corpo de um HTTP não-2xx.
  String? _extractHttpBodyError(String body) {
    try {
      final map = jsonDecode(body) as Map<String, dynamic>;
      final err = map['error'];
      if (err != null && err.toString().trim().isNotEmpty) {
        return err.toString();
      }
    } catch (_) {}
    return null;
  }

  /// Extrai a mensagem real de erro de uma exceção do functions.invoke
  /// (o corpo da resposta vem em `details`, que pode ser Map ou String).
  String _extractFunctionError(Object e) {
    try {
      final dynamic d = e;
      // FunctionException do supabase_flutter: context/details/status.
      try {
        final ctx = d.context;
        if (ctx is Map && ctx['error'] != null) {
          return ctx['error'].toString();
        }
      } catch (_) {}
      final details = d.details;
      if (details is Map) {
        final err = details['error'] ?? details['message'];
        if (err != null) return err.toString();
      } else if (details is String && details.isNotEmpty) {
        try {
          final map = jsonDecode(details) as Map<String, dynamic>;
          final err = map['error'] ?? map['message'];
          if (err != null) return err.toString();
        } catch (_) {
          return details;
        }
      }
      try {
        final msg = d.message;
        if (msg != null && msg.toString().trim().isNotEmpty) {
          return msg.toString();
        }
      } catch (_) {}
      final status = d.status;
      if (status != null) return 'Asaas recusou a cobrança (HTTP $status).';
    } catch (_) {}
    return e.toString();
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
