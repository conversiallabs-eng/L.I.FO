import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

/// Tipos de manobra mapeados do OSRM (type + modifier)
enum ManeuverType {
  turnLeft,
  turnRight,
  turnSlightLeft,
  turnSlightRight,
  turnSharpLeft,
  turnSharpRight,
  uturn,
  roundabout,
  straight,
  depart,
  arrive,
  merge,
  onRamp,
  offRamp,
  fork,
  unknown,
}

/// Um passo de navegação (turn-by-turn) retornado pelo OSRM
class RouteStep {
  final ManeuverType maneuver;
  final double distanceMeters;
  final String streetName;
  final int roundaboutExit; // 0 se não for rotatória
  /// Onde a manobra acontece (maneuver.location do OSRM, [lng, lat]).
  /// Null em steps antigos/offline — nesse caso o HUD usa fallback.
  final LatLng? location;

  const RouteStep({
    required this.maneuver,
    required this.distanceMeters,
    required this.streetName,
    this.roundaboutExit = 0,
    this.location,
  });

  /// Ícone Flutter correspondente ao tipo de manobra
  IconData get icon {
    switch (maneuver) {
      case ManeuverType.turnLeft:
        return Icons.turn_left_rounded;
      case ManeuverType.turnRight:
        return Icons.turn_right_rounded;
      case ManeuverType.turnSlightLeft:
        return Icons.turn_slight_left_rounded;
      case ManeuverType.turnSlightRight:
        return Icons.turn_slight_right_rounded;
      case ManeuverType.turnSharpLeft:
        return Icons.turn_sharp_left_rounded;
      case ManeuverType.turnSharpRight:
        return Icons.turn_sharp_right_rounded;
      case ManeuverType.uturn:
        return Icons.u_turn_left_rounded;
      case ManeuverType.roundabout:
        return Icons.roundabout_left_rounded;
      case ManeuverType.merge:
      case ManeuverType.onRamp:
        return Icons.merge_rounded;
      case ManeuverType.offRamp:
        return Icons.exit_to_app_rounded;
      case ManeuverType.fork:
        return Icons.fork_right_rounded;
      case ManeuverType.arrive:
        return Icons.location_on_rounded;
      case ManeuverType.straight:
      case ManeuverType.depart:
      case ManeuverType.unknown:
        return Icons.straight_rounded;
    }
  }

  /// Rótulo legível da manobra
  String get label {
    switch (maneuver) {
      case ManeuverType.turnLeft:
        return 'Vire à esquerda';
      case ManeuverType.turnRight:
        return 'Vire à direita';
      case ManeuverType.turnSlightLeft:
        return 'Fique à esquerda';
      case ManeuverType.turnSlightRight:
        return 'Fique à direita';
      case ManeuverType.turnSharpLeft:
        return 'Curva fechada à esquerda';
      case ManeuverType.turnSharpRight:
        return 'Curva fechada à direita';
      case ManeuverType.uturn:
        return 'Retorne';
      case ManeuverType.roundabout:
        return roundaboutExit > 0
            ? 'Rotatória – $roundaboutExit ª saída'
            : 'Entre na rotatória';
      case ManeuverType.merge:
        return 'Mescle à direita';
      case ManeuverType.onRamp:
        return 'Entre na pista';
      case ManeuverType.offRamp:
        return 'Saída da pista';
      case ManeuverType.fork:
        return 'Mantenha-se na bifurcação';
      case ManeuverType.arrive:
        return 'Chegando ao destino';
      case ManeuverType.straight:
        return 'Siga em frente';
      case ManeuverType.depart:
        return 'Siga em frente';
      case ManeuverType.unknown:
        return 'Continue';
    }
  }

  /// Distância formatada como string amigável
  String get distanceLabel {
    if (distanceMeters < 1000) {
      return '${distanceMeters.round()} m';
    }
    return '${(distanceMeters / 1000).toStringAsFixed(1)} km';
  }

  /// Converte type + modifier do OSRM para ManeuverType
  static ManeuverType fromOsrm(String type, String modifier) {
    switch (type) {
      case 'depart':
        return ManeuverType.depart;
      case 'arrive':
        return ManeuverType.arrive;
      case 'roundabout':
      case 'rotary':
      case 'roundabout turn':
        return ManeuverType.roundabout;
      case 'merge':
        return ManeuverType.merge;
      case 'on ramp':
        return ManeuverType.onRamp;
      case 'off ramp':
        return ManeuverType.offRamp;
      case 'fork':
        return ManeuverType.fork;
      case 'continue':
      case 'new name':
        return ManeuverType.straight;
      case 'turn':
      case 'end of road':
        switch (modifier) {
          case 'left':
            return ManeuverType.turnLeft;
          case 'right':
            return ManeuverType.turnRight;
          case 'slight left':
            return ManeuverType.turnSlightLeft;
          case 'slight right':
            return ManeuverType.turnSlightRight;
          case 'sharp left':
            return ManeuverType.turnSharpLeft;
          case 'sharp right':
            return ManeuverType.turnSharpRight;
          case 'uturn':
            return ManeuverType.uturn;
          case 'straight':
            return ManeuverType.straight;
          default:
            return ManeuverType.unknown;
        }
      default:
        return ManeuverType.unknown;
    }
  }
}
