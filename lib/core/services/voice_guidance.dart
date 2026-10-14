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

  bool get muted => _muted;

  Future<void> _ensureReady() async {
    if (_ready) return;
    try {
      await _tts.setLanguage('pt-BR');
      await _tts.setSpeechRate(0.95);
      await _tts.setPitch(1.0);
      await _tts.setVolume(1.0);
      // Fila por conta própria: corta a frase anterior em vez de embolar.
      _ready = true;
    } catch (e) {
      debugPrint('VoiceGuidance indisponível: $e');
    }
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
