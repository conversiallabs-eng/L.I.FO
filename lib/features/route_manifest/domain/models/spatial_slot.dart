import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';

enum SpatialSlotType {
  fundoEsquerdo,
  fundoDireito,
  meioEsquerdo,
  meioDireito,
  portaLateral,
  portaTraseira,
}

class SpatialSlot {
  final SpatialSlotType type;
  final String label;
  final String description;
  final int loadingOrder; // 1 = First to load into vehicle (Deepest)
  final int unloadingOrder; // 1 = First to unload (Closest to door - LIFO)
  final int gridRow; // 0 = Fundo, 1 = Meio, 2 = Portas
  final int gridCol; // 0 = Esquerda, 1 = Direita
  final Color visualColor;

  const SpatialSlot({
    required this.type,
    required this.label,
    required this.description,
    required this.loadingOrder,
    required this.unloadingOrder,
    required this.gridRow,
    required this.gridCol,
    required this.visualColor,
  });

  static const SpatialSlot fundoEsquerdo = SpatialSlot(
    type: SpatialSlotType.fundoEsquerdo,
    label: 'Fundo Esquerdo',
    description: 'Zona mais profunda do compartimento a esquerda',
    loadingOrder: 1,
    unloadingOrder: 6,
    gridRow: 0,
    gridCol: 0,
    visualColor: AppColors.slotDeepLeft,
  );

  static const SpatialSlot fundoDireito = SpatialSlot(
    type: SpatialSlotType.fundoDireito,
    label: 'Fundo Direito',
    description: 'Zona mais profunda do compartimento a direita',
    loadingOrder: 2,
    unloadingOrder: 5,
    gridRow: 0,
    gridCol: 1,
    visualColor: AppColors.slotDeepRight,
  );

  static const SpatialSlot meioEsquerdo = SpatialSlot(
    type: SpatialSlotType.meioEsquerdo,
    label: 'Meio Esquerdo',
    description: 'Corredor intermediario a esquerda',
    loadingOrder: 3,
    unloadingOrder: 4,
    gridRow: 1,
    gridCol: 0,
    visualColor: AppColors.slotMidLeft,
  );

  static const SpatialSlot meioDireito = SpatialSlot(
    type: SpatialSlotType.meioDireito,
    label: 'Meio Direito',
    description: 'Corredor intermediario a direita',
    loadingOrder: 4,
    unloadingOrder: 3,
    gridRow: 1,
    gridCol: 1,
    visualColor: AppColors.slotMidRight,
  );

  static const SpatialSlot portaLateral = SpatialSlot(
    type: SpatialSlotType.portaLateral,
    label: 'Porta Lateral',
    description: 'Acesso rapido pela porta lateral corredica',
    loadingOrder: 5,
    unloadingOrder: 2,
    gridRow: 2,
    gridCol: 1,
    visualColor: AppColors.slotSideDoor,
  );

  static const SpatialSlot portaTraseira = SpatialSlot(
    type: SpatialSlotType.portaTraseira,
    label: 'Porta Traseira',
    description: 'Acesso imediato de descarga pela porta traseira',
    loadingOrder: 6,
    unloadingOrder: 1,
    gridRow: 2,
    gridCol: 0,
    visualColor: AppColors.slotRearDoor,
  );

  static List<SpatialSlot> get allSlots => [
    fundoEsquerdo,
    fundoDireito,
    meioEsquerdo,
    meioDireito,
    portaLateral,
    portaTraseira,
  ];

  static SpatialSlot fromType(SpatialSlotType type) {
    switch (type) {
      case SpatialSlotType.fundoEsquerdo:
        return fundoEsquerdo;
      case SpatialSlotType.fundoDireito:
        return fundoDireito;
      case SpatialSlotType.meioEsquerdo:
        return meioEsquerdo;
      case SpatialSlotType.meioDireito:
        return meioDireito;
      case SpatialSlotType.portaLateral:
        return portaLateral;
      case SpatialSlotType.portaTraseira:
        return portaTraseira;
    }
  }

  static SpatialSlot fromString(String val) {
    for (final slot in allSlots) {
      if (slot.label.toLowerCase() == val.toLowerCase() ||
          slot.type.name.toLowerCase() == val.toLowerCase()) {
        return slot;
      }
    }
    return portaTraseira;
  }

  // Returns slot based on stop delivery sequence (1-indexed) under strict LIFO logic:
  // Delivery 1 -> Porta Traseira (First out)
  // Delivery 2 -> Porta Lateral (Second out)
  // Delivery 3 -> Meio Direito
  // Delivery 4 -> Meio Esquerdo
  // Delivery 5 -> Fundo Direito
  // Delivery 6+ -> Fundo Esquerdo
  static SpatialSlot slotForDeliverySequence(int sequenceNumber, int totalStops) {
    final clamped = sequenceNumber <= 0 ? 1 : sequenceNumber;
    switch (clamped) {
      case 1:
        return portaTraseira;
      case 2:
        return portaLateral;
      case 3:
        return meioDireito;
      case 4:
        return meioEsquerdo;
      case 5:
        return fundoDireito;
      default:
        return fundoEsquerdo;
    }
  }
}
