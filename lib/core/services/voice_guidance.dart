import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import '../models/route_step.dart';

/// Voz do GPS estilo Waze (usa a voz do sistema, sem API key).
///
/// Fala cada manobra 2x: de longe ("Em 300 metros, vire à direita...")
/// e em cima ("Vire à direita"). Rotatória canta a saída.
/// O chamador decide QUANDO anunciar (limiares); aqui é só falar/parar.
class VoiceGuidance {
  static final VoiceGuidance instance = VoiceGuidance._internal();
  VoiceGuidance._internal();

  final FlutterTts _tts = FlutterTts();
  bool _ready = false;
  bool _muted = false;

  /// Preenchido quando o aparelho NÃO tem voz em português (p/ avisar o
  /// usuário a instalar o Google TTS / baixar a voz pt-BR). Null = tudo certo.
  String? _voiceIssue;

  String? get voiceIssue => _voiceIssue;

  bool get muted => _muted;

  Future<void> _ensureReady() async {
    if (_ready) return;
    try {
      // 1. Idioma: pt-BR se existir no aparelho, senão deixa o padrão.
      try {
        final langs = await _tts.getLanguages;
        final hasPt = langs.any(
          (l) => l.toString().toLowerCase().startsWith('pt'),
        );
        if (hasPt) {
          await _tts.setLanguage('pt-BR');
        } else {
          _voiceIssue = 'sem voz em português no aparelho';
        }
      } catch (_) {
        try {
          await _tts.setLanguage('pt-BR');
        } catch (_) {}
      }

      // 2. Melhor voz pt-BR: prefere rede/Google (o sistema baixa sozinho
      // com internet — é o "patch" de voz, grátis).
      try {
        final voices = await _tts.getVoices;
        Map<String, dynamic>? best;
        for (final v in voices) {
          final m = Map<String, dynamic>.from(v as Map);
          final locale = (m['locale'] ?? '').toString().toLowerCase();
          if (!locale.startsWith('pt')) continue;
          best ??= m;
          final quality = m['quality']?.toString() ?? '';
          final name = (m['name'] ?? '').toString().toLowerCase();
          if (quality == '300' ||
              name.contains('google') ||
              name.contains('network')) {
            best = m;
            break;
          }
        }
        if (best != null) {
          await _tts.setVoice({
            'name': best['name'] as String,
            'locale': best['locale'] as String,
          });
          _voiceIssue = null;
          debugPrint('VoiceGuidance usando voz ${best['name']}');
        }
      } catch (e) {
        debugPrint('VoiceGuidance sem troca de voz: $e');
      }

      await _tts.setSpeechRate(0.95);
      await _tts.setPitch(1.0);
      await _tts.setVolume(1.0);
      _ready = true;
    } catch (e) {
      debugPrint('VoiceGuidance indisponível: $e');
    }
  }

  /// Garante o motor pronto e diz se há voz em português.
  Future<String?> checkVoice() async {
    await _ensureReady();
    return _voiceIssue;
  }

  /// Liga/desliga a voz. Ao mutar, cala na hora.
  Future<void> setMuted(bool muted) async {
    _muted = muted;
    if (muted) {
      try {
        await _tts.stop();
      } catch (_) {}
    }
  }

  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }

  Future<void> speak(String text) async {
    if (_muted || text.trim().isEmpty) return;
    await _ensureReady();
    if (_muted) return;
    try {
      await _tts.stop();
      await _tts.speak(text);
    } catch (e) {
      debugPrint('VoiceGuidance falhou ao falar: $e');
    }
  }

  /// Abertura imediata ao iniciar a rota (não espera manobra nenhuma).
  /// "Rota iniciada! Destino: Rua Tom Jobim. Siga em frente."
  String openingInstruction(String destination, [double? totalMeters]) {
    var text = 'Rota iniciada! Destino: $destination.';
    if (totalMeters != null && totalMeters > 0) {
      text += ' Distância total: ${_spokenDistance(totalMeters)}.';
    }
    text += ' Siga em frente.';
    return text;
  }

  /// "Em 300 metros, vire à direita na Rua Tom Jobim".
  String farInstruction(RouteStep step, double metersTo) =>
      'Em ${_spokenDistance(metersTo)}, ${step.label}${_streetSuffix(step)}';

  /// "Vire à direita".
  String nearInstruction(RouteStep step) =>
      '${step.label}${_streetSuffix(step)}';

  String _streetSuffix(RouteStep step) {
    final s = step.streetName.trim();
    if (s.isEmpty) return '';
    if (step.maneuver == ManeuverType.arrive) return '';
    return ' na $s';
  }

  /// "300 metros" / "1,2 quilômetros" (fala com vírgula, como gente).
  static String _spokenDistance(double meters) {
    if (meters < 1000) return '${meters.round()} metros';
    final km = meters / 1000.0;
    final txt = km >= 10
        ? km.toStringAsFixed(0)
        : km.toStringAsFixed(1).replaceAll('.', ',');
    return '$txt ${km >= 2 ? 'quilômetros' : 'quilômetro'}';
  }
}
