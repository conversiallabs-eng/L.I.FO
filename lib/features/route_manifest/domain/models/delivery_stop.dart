import 'package_item.dart';
import 'spatial_slot.dart';

enum StopStatus {
  pending,
  inTransit,
  completed,
  failed,
}

class DeliveryStop {
  final String id;
  final String manifestVersionId;
  final int sequenceIndex;
  final String recipientName;
  final String address;
  final double latitude;
  final double longitude;
  final StopStatus status;
  final SpatialSlot spatialSlot;
  final String? timeWindow;
  final String? notes;
  final List<PackageItem> packages;
  final DateTime? completedAt;

  const DeliveryStop({
    required this.id,
    required this.manifestVersionId,
    required this.sequenceIndex,
    required this.recipientName,
    required this.address,
    required this.latitude,
    required this.longitude,
    this.status = StopStatus.pending,
    required this.spatialSlot,
    this.timeWindow,
    this.notes,
    this.packages = const [],
    this.completedAt,
  });

  bool get isAllPackagesLoaded {
    if (packages.isEmpty) return false;
    return packages.every((p) =>
        p.status == PackageStatus.loaded ||
        p.status == PackageStatus.delivered ||
        p.status == PackageStatus.failed);
  }

  int get loadedPackagesCount {
    return packages
        .where((p) =>
            p.status == PackageStatus.loaded ||
            p.status == PackageStatus.delivered ||
            p.status == PackageStatus.failed)
        .length;
  }

  DeliveryStop copyWith({
    String? id,
    String? manifestVersionId,
    int? sequenceIndex,
    String? recipientName,
    String? address,
    double? latitude,
    double? longitude,
    StopStatus? status,
    SpatialSlot? spatialSlot,
    String? timeWindow,
    String? notes,
    List<PackageItem>? packages,
    DateTime? completedAt,
    bool clearCompletedAt = false,
  }) {
    return DeliveryStop(
      id: id ?? this.id,
      manifestVersionId: manifestVersionId ?? this.manifestVersionId,
      sequenceIndex: sequenceIndex ?? this.sequenceIndex,
      recipientName: recipientName ?? this.recipientName,
      address: address ?? this.address,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      status: status ?? this.status,
      spatialSlot: spatialSlot ?? this.spatialSlot,
      timeWindow: timeWindow ?? this.timeWindow,
      notes: notes ?? this.notes,
      packages: packages ?? this.packages,
      completedAt: clearCompletedAt ? null : (completedAt ?? this.completedAt),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'manifest_version_id': manifestVersionId,
      'sequence_index': sequenceIndex,
      'recipient_name': recipientName,
      'address': address,
      'latitude': latitude,
      'longitude': longitude,
      'status': status.name,
      'spatial_slot': spatialSlot.label,
      'time_window': timeWindow,
      'notes': notes,
      'completed_at': completedAt?.toIso8601String(),
    };
  }

  factory DeliveryStop.fromMap(Map<String, dynamic> map, {List<PackageItem> packages = const []}) {
    return DeliveryStop(
      id: map['id'] as String,
      manifestVersionId: map['manifest_version_id'] as String,
      sequenceIndex: map['sequence_index'] as int,
      recipientName: map['recipient_name'] as String,
      address: map['address'] as String,
      latitude: (map['latitude'] as num).toDouble(),
      longitude: (map['longitude'] as num).toDouble(),
      status: StopStatus.values.byName(map['status'] as String? ?? 'pending'),
      spatialSlot: SpatialSlot.fromString(map['spatial_slot'] as String),
      timeWindow: map['time_window'] as String?,
      notes: map['notes'] as String?,
      packages: packages,
      completedAt: map['completed_at'] != null ? DateTime.tryParse(map['completed_at'] as String) : null,
    );
  }
}
