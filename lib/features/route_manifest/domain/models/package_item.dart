import 'spatial_slot.dart';

enum PackageStatus {
  pendingLoad,
  loaded,
  delivered,
}

class PackageItem {
  final String id;
  final String manifestVersionId;
  final String stopId;
  final String barcode;
  final String description;
  final double weightKg;
  final double volumeM3;
  final SpatialSlot spatialSlot;
  final PackageStatus status;
  final DateTime? scannedAt;

  const PackageItem({
    required this.id,
    required this.manifestVersionId,
    required this.stopId,
    required this.barcode,
    required this.description,
    required this.weightKg,
    this.volumeM3 = 0.05,
    required this.spatialSlot,
    this.status = PackageStatus.pendingLoad,
    this.scannedAt,
  });

  PackageItem copyWith({
    String? id,
    String? manifestVersionId,
    String? stopId,
    String? barcode,
    String? description,
    double? weightKg,
    double? volumeM3,
    SpatialSlot? spatialSlot,
    PackageStatus? status,
    DateTime? scannedAt,
  }) {
    return PackageItem(
      id: id ?? this.id,
      manifestVersionId: manifestVersionId ?? this.manifestVersionId,
      stopId: stopId ?? this.stopId,
      barcode: barcode ?? this.barcode,
      description: description ?? this.description,
      weightKg: weightKg ?? this.weightKg,
      volumeM3: volumeM3 ?? this.volumeM3,
      spatialSlot: spatialSlot ?? this.spatialSlot,
      status: status ?? this.status,
      scannedAt: scannedAt ?? this.scannedAt,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'manifest_version_id': manifestVersionId,
      'stop_id': stopId,
      'barcode': barcode,
      'description': description,
      'weight_kg': weightKg,
      'volume_m3': volumeM3,
      'spatial_slot': spatialSlot.label,
      'status': status.name,
      'scanned_at': scannedAt?.toIso8601String(),
    };
  }

  factory PackageItem.fromMap(Map<String, dynamic> map) {
    return PackageItem(
      id: map['id'] as String,
      manifestVersionId: map['manifest_version_id'] as String,
      stopId: map['stop_id'] as String,
      barcode: map['barcode'] as String,
      description: map['description'] as String,
      weightKg: (map['weight_kg'] as num).toDouble(),
      volumeM3: (map['volume_m3'] as num?)?.toDouble() ?? 0.05,
      spatialSlot: SpatialSlot.fromString(map['spatial_slot'] as String),
      status: PackageStatus.values.byName(map['status'] as String? ?? 'pendingLoad'),
      scannedAt: map['scanned_at'] != null ? DateTime.parse(map['scanned_at'] as String) : null,
    );
  }
}
