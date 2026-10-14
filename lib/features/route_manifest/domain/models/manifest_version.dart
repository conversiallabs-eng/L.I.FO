import 'delivery_stop.dart';

class ManifestVersion {
  final String id;
  final int versionIndex; // 0 = Manifesto Original, 1 = Rota Otimizada 1, etc.
  final String label;
  final String? parentVersionId;
  final String rawData;
  final DateTime createdAt;
  final bool isCurrent;
  final int totalStops;
  final int totalPackages;
  final List<DeliveryStop> stops;

  const ManifestVersion({
    required this.id,
    required this.versionIndex,
    required this.label,
    this.parentVersionId,
    required this.rawData,
    required this.createdAt,
    this.isCurrent = false,
    required this.totalStops,
    required this.totalPackages,
    this.stops = const [],
  });

  bool get isOriginal => versionIndex == 0;

  int get loadedPackagesCount {
    int count = 0;
    for (final stop in stops) {
      count += stop.loadedPackagesCount;
    }
    return count;
  }

  int get totalPackagesInStops {
    int count = 0;
    for (final stop in stops) {
      count += stop.packages.length;
    }
    return count;
  }

  double get loadingProgress {
    if (totalPackagesInStops == 0) return 0.0;
    return loadedPackagesCount / totalPackagesInStops;
  }

  ManifestVersion copyWith({
    String? id,
    int? versionIndex,
    String? label,
    String? parentVersionId,
    String? rawData,
    DateTime? createdAt,
    bool? isCurrent,
    int? totalStops,
    int? totalPackages,
    List<DeliveryStop>? stops,
  }) {
    return ManifestVersion(
      id: id ?? this.id,
      versionIndex: versionIndex ?? this.versionIndex,
      label: label ?? this.label,
      parentVersionId: parentVersionId ?? this.parentVersionId,
      rawData: rawData ?? this.rawData,
      createdAt: createdAt ?? this.createdAt,
      isCurrent: isCurrent ?? this.isCurrent,
      totalStops: totalStops ?? this.totalStops,
      totalPackages: totalPackages ?? this.totalPackages,
      stops: stops ?? this.stops,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'version_index': versionIndex,
      'label': label,
      'parent_version_id': parentVersionId,
      'raw_data': rawData,
      'created_at': createdAt.toIso8601String(),
      'is_current': isCurrent ? 1 : 0,
      'total_stops': totalStops,
      'total_packages': totalPackages,
    };
  }

  factory ManifestVersion.fromMap(Map<String, dynamic> map, {List<DeliveryStop> stops = const []}) {
    return ManifestVersion(
      id: map['id'] as String,
      versionIndex: map['version_index'] as int,
      label: map['label'] as String,
      parentVersionId: map['parent_version_id'] as String?,
      rawData: map['raw_data'] as String,
      createdAt: DateTime.parse(map['created_at'] as String),
      isCurrent: (map['is_current'] as int) == 1,
      totalStops: map['total_stops'] as int,
      totalPackages: map['total_packages'] as int,
      stops: stops,
    );
  }
}
