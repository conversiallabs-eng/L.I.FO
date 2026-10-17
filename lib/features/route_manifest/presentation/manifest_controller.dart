import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import '../data/manifest_repository.dart';
import '../domain/models/manifest_version.dart';
import '../domain/models/delivery_stop.dart';
import '../domain/models/package_item.dart';
import '../domain/models/spatial_slot.dart';
import '../../../core/services/hybrid_routing_service.dart';
import '../../../core/services/manifest_import_service.dart';
import '../../../core/network/net_guard.dart';

class ManifestState {
  final ManifestVersion? currentVersion;
  final List<ManifestVersion> versionHistory;
  final List<LatLng> roadPolyline;
  final bool isOnlineRouting;
  final double totalDistanceMeters;
  final double totalDurationSeconds;
  final List<double> arrivalOffsets;
  final DateTime? routeComputedAt;
  final bool hasGpsStart;
  final bool isLoading;
  final String? errorMessage;
  final PackageItem? lastScannedPackage;
  final DeliveryStop? lastScannedStop;
  final String? scanFeedbackMessage;
  final bool scanSuccess;

  const ManifestState({
    this.currentVersion,
    this.versionHistory = const [],
    this.roadPolyline = const [],
    this.isOnlineRouting = false,
    this.totalDistanceMeters = 0,
    this.totalDurationSeconds = 0,
    this.arrivalOffsets = const [],
    this.routeComputedAt,
    this.hasGpsStart = false,
    this.isLoading = false,
    this.errorMessage,
    this.lastScannedPackage,
    this.lastScannedStop,
    this.scanFeedbackMessage,
    this.scanSuccess = false,
  });

  ManifestState copyWith({
    ManifestVersion? currentVersion,
    bool clearCurrentVersion = false,
    List<ManifestVersion>? versionHistory,
    List<LatLng>? roadPolyline,
    bool clearRoadPolyline = false,
    bool? isOnlineRouting,
    double? totalDistanceMeters,
    double? totalDurationSeconds,
    List<double>? arrivalOffsets,
    DateTime? routeComputedAt,
    bool? hasGpsStart,
    bool? isLoading,
    String? errorMessage,
    PackageItem? lastScannedPackage,
    DeliveryStop? lastScannedStop,
    String? scanFeedbackMessage,
    bool? scanSuccess,
  }) {
    return ManifestState(
      currentVersion: clearCurrentVersion ? null : (currentVersion ?? this.currentVersion),
      versionHistory: versionHistory ?? this.versionHistory,
      roadPolyline: clearRoadPolyline ? const [] : (roadPolyline ?? this.roadPolyline),
      isOnlineRouting: isOnlineRouting ?? this.isOnlineRouting,
      totalDistanceMeters: totalDistanceMeters ?? this.totalDistanceMeters,
      totalDurationSeconds: totalDurationSeconds ?? this.totalDurationSeconds,
      arrivalOffsets: arrivalOffsets ?? this.arrivalOffsets,
      routeComputedAt: routeComputedAt ?? this.routeComputedAt,
      hasGpsStart: hasGpsStart ?? this.hasGpsStart,
      isLoading: isLoading ?? this.isLoading,
      errorMessage: errorMessage,
      lastScannedPackage: lastScannedPackage ?? this.lastScannedPackage,
      lastScannedStop: lastScannedStop ?? this.lastScannedStop,
      scanFeedbackMessage: scanFeedbackMessage,
      scanSuccess: scanSuccess ?? this.scanSuccess,
    );
  }
}

class ManifestNotifier extends StateNotifier<ManifestState> {
  final ManifestRepository _repository;

  ManifestNotifier(this._repository) : super(const ManifestState()) {
    init();
  }

  Future<void> init({double? startLat, double? startLng}) async {
    state = state.copyWith(isLoading: true, errorMessage: null);
    try {
      if (startLat == null || startLng == null) {
        try {
          final last = await Geolocator.getLastKnownPosition();
          if (last != null) {
            startLat = last.latitude;
            startLng = last.longitude;
          }
        } catch (_) {}
      }

      final current = await _repository.getOrInitCurrentManifest();
      if (current == null || current.stops.isEmpty) {
        state = const ManifestState(isLoading: false);
        return;
      }
      final history = await _repository.getVersionHistory();
      final routing = await _repository.fetchGeometry(
        current.stops,
        startLat: startLat,
        startLng: startLng,
      );

      state = state.copyWith(
        currentVersion: current,
        versionHistory: history,
        roadPolyline: routing.polylinePoints,
        isOnlineRouting: routing.isOnline,
        totalDistanceMeters: routing.totalDistanceMeters,
        totalDurationSeconds: routing.totalDurationSeconds,
        arrivalOffsets: RoutingResult.arrivalOffsets(
          legDurations: routing.legDurationsSeconds,
          stopCount: current.stops.length,
          hasStart: startLat != null && startLng != null,
        ),
        routeComputedAt: routing.isOnline ? DateTime.now() : null,
        hasGpsStart: startLat != null && startLng != null,
        isLoading: false,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: 'Erro ao carregar manifesto de rotas: ${e.toString()}',
      );
    }
  }

  Future<void> reoptimizeRoute({double? startLat, double? startLng}) async {
    final current = state.currentVersion;
    if (current == null) return;

    // Offline, reotimizar seria criar uma versão nova vazia e aposentar a
    // versão que tem a rua salva — ou seja, apagar a linha do mapa à toa
    // (a ordem sem OSRM nem mudaria). No-op silencioso; o botão manual
    // avisa via SnackBar e o auto-boot só pula.
    if (await isOfflineFast()) return;

    state = state.copyWith(isLoading: true, errorMessage: null);
    try {
      final result = await _repository.reoptimizeRoute(
        current,
        startLat: startLat,
        startLng: startLng,
      );
      final history = await _repository.getVersionHistory();

      state = state.copyWith(
        currentVersion: result.version,
        versionHistory: history,
        roadPolyline: result.polyline,
        isOnlineRouting: result.isOnline,
        totalDistanceMeters: result.distanceMeters,
        totalDurationSeconds: result.durationSeconds,
        arrivalOffsets: result.arrivalOffsets,
        routeComputedAt: result.isOnline ? DateTime.now() : null,
        hasGpsStart: startLat != null && startLng != null,
        isLoading: false,
      );
      HapticFeedback.mediumImpact();
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: 'Falha na otimizacao da rota: ${e.toString()}',
      );
    }
  }

  Future<bool> addStop({
    required String recipientName,
    required String address,
    required double latitude,
    required double longitude,
    required List<NewPackageInput> packages,
    double? startLat,
    double? startLng,
  }) async {
    if (packages.isEmpty) {
      state = state.copyWith(errorMessage: 'Adicione ao menos um volume.');
      return false;
    }
    state = state.copyWith(isLoading: true, errorMessage: null);
    try {
      final result = await _repository.addStop(
        recipientName: recipientName,
        address: address,
        latitude: latitude,
        longitude: longitude,
        packages: packages,
        startLat: startLat,
        startLng: startLng,
      );
      final history = await _repository.getVersionHistory();

      state = state.copyWith(
        currentVersion: result.version,
        versionHistory: history,
        roadPolyline: result.polyline,
        isOnlineRouting: result.isOnline,
        totalDistanceMeters: result.distanceMeters,
        totalDurationSeconds: result.durationSeconds,
        arrivalOffsets: result.arrivalOffsets,
        routeComputedAt: result.isOnline ? DateTime.now() : null,
        hasGpsStart: startLat != null && startLng != null,
        isLoading: false,
      );
      HapticFeedback.mediumImpact();
      return true;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: 'Falha ao adicionar parada: ${e.toString()}',
      );
      return false;
    }
  }

  Future<bool> importManifest({
    required String formatName,
    required List<ResolvedImportStop> stops,
    double? startLat,
    double? startLng,
  }) async {
    if (stops.isEmpty) {
      state = state.copyWith(errorMessage: 'Nenhuma parada localizada para importar.');
      return false;
    }
    state = state.copyWith(isLoading: true, errorMessage: null);
    try {
      final result = await _repository.importManifest(
        formatName: formatName,
        stops: stops,
        startLat: startLat,
        startLng: startLng,
      );
      final history = await _repository.getVersionHistory();

      state = state.copyWith(
        currentVersion: result.version,
        versionHistory: history,
        roadPolyline: result.polyline,
        isOnlineRouting: result.isOnline,
        totalDistanceMeters: result.distanceMeters,
        totalDurationSeconds: result.durationSeconds,
        arrivalOffsets: result.arrivalOffsets,
        routeComputedAt: result.isOnline ? DateTime.now() : null,
        hasGpsStart: startLat != null && startLng != null,
        isLoading: false,
      );
      HapticFeedback.mediumImpact();
      return true;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: 'Falha ao importar manifesto: ${e.toString()}',
      );
      return false;
    }
  }

  Future<bool> renameVersion(String versionId, String newLabel) async {
    final trimmed = newLabel.trim();
    if (trimmed.isEmpty) return false;

    final history = await _repository.getVersionHistory();
    final conflict = history.any((v) => v.id != versionId && v.label.trim().toLowerCase() == trimmed.toLowerCase());
    if (conflict) {
      state = state.copyWith(errorMessage: 'Já existe uma rota com o nome "$trimmed".');
      return false;
    }

    await _repository.updateVersionLabel(versionId, trimmed);
    final updatedCurrent = await _repository.getOrInitCurrentManifest();
    final updatedHistory = await _repository.getVersionHistory();
    state = state.copyWith(
      currentVersion: updatedCurrent,
      versionHistory: updatedHistory,
    );
    HapticFeedback.lightImpact();
    return true;
  }

  Future<void> renameCurrentManifest(String newLabel) async {
    final v = state.currentVersion;
    if (v == null) return;
    await renameVersion(v.id, newLabel);
  }

  Future<void> deleteVersion(String versionId) async {
    state = state.copyWith(isLoading: true, errorMessage: null);
    try {
      await _repository.deleteVersion(versionId);
      final current = await _repository.getOrInitCurrentManifest();
      final history = await _repository.getVersionHistory();

      if (current == null) {
        state = const ManifestState(isLoading: false);
        HapticFeedback.mediumImpact();
        return;
      }

      final routing = await _repository.fetchGeometry(current.stops);
      state = state.copyWith(
        currentVersion: current,
        versionHistory: history,
        roadPolyline: routing.polylinePoints,
        isOnlineRouting: routing.isOnline,
        totalDistanceMeters: routing.totalDistanceMeters,
        totalDurationSeconds: routing.totalDurationSeconds,
        arrivalOffsets: RoutingResult.arrivalOffsets(
          legDurations: routing.legDurationsSeconds,
          stopCount: current.stops.length,
          hasStart: false,
        ),
        routeComputedAt: routing.isOnline ? DateTime.now() : null,
        isLoading: false,
      );
      HapticFeedback.mediumImpact();
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: 'Falha ao excluir versão: $e',
      );
    }
  }

  Future<void> deleteManifestCascade(String rootManifestId) async {
    state = state.copyWith(isLoading: true, errorMessage: null);
    try {
      await _repository.deleteManifestCascade(rootManifestId);
      final current = await _repository.getOrInitCurrentManifest();
      final history = await _repository.getVersionHistory();

      if (current == null) {
        state = const ManifestState(isLoading: false);
        HapticFeedback.heavyImpact();
        return;
      }

      final routing = await _repository.fetchGeometry(current.stops);
      state = state.copyWith(
        currentVersion: current,
        versionHistory: history,
        roadPolyline: routing.polylinePoints,
        isOnlineRouting: routing.isOnline,
        totalDistanceMeters: routing.totalDistanceMeters,
        totalDurationSeconds: routing.totalDurationSeconds,
        arrivalOffsets: RoutingResult.arrivalOffsets(
          legDurations: routing.legDurationsSeconds,
          stopCount: current.stops.length,
          hasStart: false,
        ),
        routeComputedAt: routing.isOnline ? DateTime.now() : null,
        isLoading: false,
      );
      HapticFeedback.heavyImpact();
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: 'Falha ao limpar manifesto em cascata: $e',
      );
    }
  }

  Future<void> revertToVersion(String targetVersionId, {double? startLat, double? startLng}) async {
    state = state.copyWith(isLoading: true, errorMessage: null);
    try {
      final restored = await _repository.revertToVersion(targetVersionId);
      final history = await _repository.getVersionHistory();
      final routing = await _repository.fetchGeometry(
        restored.stops,
        startLat: startLat,
        startLng: startLng,
      );

      state = state.copyWith(
        currentVersion: restored,
        versionHistory: history,
        roadPolyline: routing.polylinePoints,
        isOnlineRouting: routing.isOnline,
        totalDistanceMeters: routing.totalDistanceMeters,
        totalDurationSeconds: routing.totalDurationSeconds,
        arrivalOffsets: RoutingResult.arrivalOffsets(
          legDurations: routing.legDurationsSeconds,
          stopCount: restored.stops.length,
          hasStart: startLat != null && startLng != null,
        ),
        routeComputedAt: routing.isOnline ? DateTime.now() : null,
        hasGpsStart: startLat != null && startLng != null,
        isLoading: false,
      );
      HapticFeedback.lightImpact();
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: 'Falha ao reverter versao de rota: ${e.toString()}',
      );
    }
  }

  /// Resolve o código para a parada dona SEM efeitos colaterais (não marca
  /// como carregado). Usado pela validação QR + GPS do card de navegação.
  /// Retorna null se o código não está no manifesto atual.
  Future<DeliveryStop?> findStopForBarcode(String barcode) async {
    final trimmed = barcode.trim();
    if (trimmed.isEmpty) return null;
    if (state.currentVersion == null) {
      final fresh = await _repository.getOrInitCurrentManifest();
      if (fresh == null) return null;
      state = state.copyWith(currentVersion: fresh);
    }
    final match = await _repository.lookupBarcode(trimmed);
    if (match == null) return null;
    return match['stop'] as DeliveryStop;
  }

  Future<bool> handleInstantScan(String barcode) async {
    final trimmed = barcode.trim();
    if (trimmed.isEmpty) return false;

    if (state.currentVersion == null) {
      HapticFeedback.heavyImpact();
      state = state.copyWith(
        scanSuccess: false,
        scanFeedbackMessage: 'Nenhum manifesto ativo — adicione paradas primeiro.',
      );
      return false;
    }

    final match = await _repository.lookupBarcode(trimmed);
    if (match == null) {
      HapticFeedback.heavyImpact();
      state = state.copyWith(
        scanSuccess: false,
        scanFeedbackMessage: 'Codigo nao encontrado no manifesto atual: $trimmed',
      );
      return false;
    }

    final pkg = match['package'] as PackageItem;
    final stop = match['stop'] as DeliveryStop;

    SystemSound.play(SystemSoundType.click);
    HapticFeedback.mediumImpact();

    if (pkg.status == PackageStatus.loaded) {
      final reScannedPkg = pkg.copyWith(
        scannedAt: DateTime.now(),
      );
      state = state.copyWith(
        lastScannedPackage: reScannedPkg,
        lastScannedStop: stop,
        scanSuccess: true,
        scanFeedbackMessage: 'Parada #${stop.sequenceIndex} (Reconferido: ${pkg.barcode})',
      );
      return true;
    }

    await _repository.markPackageLoaded(trimmed);

    final updatedVersion = await _repository.getOrInitCurrentManifest();
    final updatedPkg = pkg.copyWith(
      status: PackageStatus.loaded,
      scannedAt: DateTime.now(),
    );

    state = state.copyWith(
      currentVersion: updatedVersion,
      lastScannedPackage: updatedPkg,
      lastScannedStop: stop,
      scanSuccess: true,
      scanFeedbackMessage: 'Parada #${stop.sequenceIndex} confirmada',
    );

    return true;
  }

  /// Vincula um novo pacote (barcode) diretamente a uma parada existente.
  /// Usado quando o scanner lê um código desconhecido e o usuário escolhe
  /// associá-lo a uma parada já cadastrada.
  Future<bool> addPackageToStop({
    required String stopId,
    required String barcode,
    required String description,
    required double? weightKg,
  }) async {
    try {
      await _repository.addPackageToExistingStop(
        stopId: stopId,
        barcode: barcode,
        description: description,
        weightKg: weightKg,
      );
      final updatedVersion = await _repository.getOrInitCurrentManifest();
      DeliveryStop? targetStop;
      PackageItem? targetPkg;
      if (updatedVersion != null) {
        for (final s in updatedVersion.stops) {
          if (s.id == stopId) {
            targetStop = s;
            for (final p in s.packages) {
              if (p.barcode == barcode.trim()) {
                targetPkg = p;
                break;
              }
            }
            break;
          }
        }
      }
      state = state.copyWith(
        currentVersion: updatedVersion,
        lastScannedPackage: targetPkg,
        lastScannedStop: targetStop,
        scanSuccess: true,
        scanFeedbackMessage: targetStop != null
            ? 'Pacote vinculado à Parada #${targetStop.sequenceIndex}'
            : null,
      );
      return true;
    } catch (e) {
      state = state.copyWith(errorMessage: 'Erro ao vincular pacote: $e');
      return false;
    }
  }

  /// Bipagem por quadrado do baú: move o pacote p/ o compartimento e marca
  /// como carregado. Retorna o pacote ou null se o código não está no manifesto.
  Future<PackageItem?> assignPackageToSlot({
    required String barcode,
    required SpatialSlot slot,
  }) async {
    final updated =
        await _repository.assignPackageToSlot(barcode: barcode, slot: slot);
    if (updated == null) return null;
    HapticFeedback.mediumImpact();
    final fresh = await _repository.getOrInitCurrentManifest();
    state = state.copyWith(currentVersion: fresh ?? state.currentVersion);
    return updated;
  }

  /// "X" do painel do baú: tira o volume do compartimento escolhido e o
  /// devolve ao compartimento automático. Segue marcado como carregado.
  Future<bool> unassignPackageFromSlot(String barcode) async {
    final ok = await _repository.unassignPackageFromSlot(barcode);
    if (!ok) return false;
    HapticFeedback.selectionClick();
    final fresh = await _repository.getOrInitCurrentManifest();
    state = state.copyWith(currentVersion: fresh ?? state.currentVersion);
    return true;
  }

  Future<void> updateStopStatus(String stopId, StopStatus newStatus) async {
    final curVer = state.currentVersion;
    if (curVer == null) return;

    // 1. Atualização otimista IMEDIATA (a tela reage instantaneamente sem esperar banco ou rede)
    final updatedStops = curVer.stops.map((s) {
      if (s.id == stopId) {
        final updatedPkgs = s.packages.map((p) {
          if (newStatus == StopStatus.completed) {
            return p.copyWith(status: PackageStatus.delivered);
          } else if (newStatus == StopStatus.failed) {
            return p.copyWith(status: PackageStatus.failed);
          } else {
            return p.copyWith(status: PackageStatus.loaded);
          }
        }).toList();
        final isDone = newStatus == StopStatus.completed || newStatus == StopStatus.failed;
        return s.copyWith(
          status: newStatus,
          packages: updatedPkgs,
          completedAt: isDone ? DateTime.now() : null,
          clearCompletedAt: !isDone,
        );
      }
      return s;
    }).toList();
    final optimisticVersion = curVer.copyWith(stops: updatedStops);
    state = state.copyWith(currentVersion: optimisticVersion);

    // 2. Persiste no SQLite
    await _repository.updateStopStatus(stopId, newStatus);
    final dbVersion = await _repository.getOrInitCurrentManifest() ?? optimisticVersion;

    // 3. Recalcula traçado de pendentes em segundo plano
    List<LatLng> newPolyline = state.roadPolyline;
    final pendingStops = dbVersion.stops.where(
      (s) => s.status == StopStatus.pending || s.status == StopStatus.inTransit,
    ).toList();

    if (pendingStops.isNotEmpty) {
      try {
        double? curLat;
        double? curLng;
        try {
          final pos = await Geolocator.getLastKnownPosition();
          if (pos != null) {
            curLat = pos.latitude;
            curLng = pos.longitude;
          }
        } catch (_) {}

        final routing = await _repository.fetchGeometry(
          pendingStops,
          startLat: curLat,
          startLng: curLng,
        );
        if (routing.polylinePoints.isNotEmpty) {
          newPolyline = routing.polylinePoints;
        }
      } catch (_) {}
    } else {
      newPolyline = const [];
    }

    state = state.copyWith(
      currentVersion: dbVersion,
      roadPolyline: newPolyline,
    );
  }

  Future<void> updatePackageStatus({
    required String packageId,
    required String stopId,
    required PackageStatus newStatus,
  }) async {
    final curVer = state.currentVersion;
    if (curVer == null) return;

    StopStatus? derivedStopStatus;
    final updatedStops = curVer.stops.map((s) {
      if (s.id == stopId) {
        final updatedPkgs = s.packages.map((p) {
          if (p.id == packageId) {
            return p.copyWith(status: newStatus);
          }
          return p;
        }).toList();

        final allDone = updatedPkgs.isNotEmpty &&
            updatedPkgs.every((p) =>
                p.status == PackageStatus.delivered ||
                p.status == PackageStatus.failed);

        StopStatus nextStopStatus = s.status;
        if (allDone) {
          final allFailed =
              updatedPkgs.every((p) => p.status == PackageStatus.failed);
          nextStopStatus = allFailed ? StopStatus.failed : StopStatus.completed;
        } else {
          if (s.status == StopStatus.completed || s.status == StopStatus.failed) {
            nextStopStatus = StopStatus.inTransit;
          }
        }
        derivedStopStatus = nextStopStatus;

        return s.copyWith(
          status: nextStopStatus,
          packages: updatedPkgs,
        );
      }
      return s;
    }).toList();

    final optimisticVersion = curVer.copyWith(stops: updatedStops);
    state = state.copyWith(currentVersion: optimisticVersion);

    await _repository.updatePackageStatus(packageId, newStatus);
    if (derivedStopStatus != null) {
      await _repository.updateStopStatus(stopId, derivedStopStatus!);
    }

    final dbVersion =
        await _repository.getOrInitCurrentManifest() ?? optimisticVersion;
    state = state.copyWith(currentVersion: dbVersion);
  }

  Future<bool> editStopAddressAndReoptimize({
    required String stopId,
    required String newAddress,
    double? newLat,
    double? newLng,
    double? startLat,
    double? startLng,
  }) async {
    state = state.copyWith(isLoading: true, errorMessage: null);
    try {
      double? sLat = startLat;
      double? sLng = startLng;
      if (sLat == null || sLng == null) {
        try {
          final pos = await Geolocator.getLastKnownPosition();
          if (pos != null) {
            sLat = pos.latitude;
            sLng = pos.longitude;
          }
        } catch (_) {}
      }

      final result = await _repository.updateStopAddressAndReoptimize(
        stopId: stopId,
        newAddress: newAddress,
        newLat: newLat,
        newLng: newLng,
        startLat: sLat,
        startLng: sLng,
      );
      final history = await _repository.getVersionHistory();

      // Encontra a parada atualizada no novo manifesto para refletir na interface
      DeliveryStop? updatedStop;
      for (final s in result.version.stops) {
        if (s.address == newAddress || s.recipientName == state.lastScannedStop?.recipientName) {
          updatedStop = s;
          break;
        }
      }
      updatedStop ??= result.version.stops.isNotEmpty ? result.version.stops.first : state.lastScannedStop;

      state = state.copyWith(
        currentVersion: result.version,
        versionHistory: history,
        roadPolyline: result.polyline,
        isOnlineRouting: result.isOnline,
        totalDistanceMeters: result.distanceMeters,
        totalDurationSeconds: result.durationSeconds,
        arrivalOffsets: result.arrivalOffsets,
        routeComputedAt: result.isOnline ? DateTime.now() : null,
        lastScannedStop: updatedStop,
        hasGpsStart: sLat != null && sLng != null,
        isLoading: false,
        scanFeedbackMessage: 'Parada #${updatedStop?.sequenceIndex ?? ""} atualizada e rota reotimizada!',
      );
      HapticFeedback.heavyImpact();
      return true;
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: 'Falha ao reotimizar: ${e.toString()}',
      );
      return false;
    }
  }

  Future<void> removeStop(String stopId, {double? startLat, double? startLng}) async {
    state = state.copyWith(isLoading: true, errorMessage: null);
    try {
      final result = await _repository.removeStop(
        stopId: stopId,
        startLat: startLat,
        startLng: startLng,
      );
      final history = await _repository.getVersionHistory();

      state = state.copyWith(
        currentVersion: result.version,
        versionHistory: history,
        roadPolyline: result.polyline,
        isOnlineRouting: result.isOnline,
        totalDistanceMeters: result.distanceMeters,
        totalDurationSeconds: result.durationSeconds,
        arrivalOffsets: result.arrivalOffsets,
        routeComputedAt: result.isOnline ? DateTime.now() : null,
        hasGpsStart: startLat != null && startLng != null,
        isLoading: false,
      );
      HapticFeedback.mediumImpact();
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: 'Falha ao remover parada: ${e.toString()}',
      );
    }
  }

  Future<bool> addQuickStop({
    required String displayName,
    required String address,
    required double latitude,
    required double longitude,
    double? startLat,
    double? startLng,
  }) async {
    final total = state.currentVersion?.totalPackagesInStops ?? 0;
    final code = 'VOL-${(total + 1).toString().padLeft(4, '0')}';

    return addStop(
      recipientName: displayName,
      address: address,
      latitude: latitude,
      longitude: longitude,
      packages: [
        NewPackageInput(barcode: code, description: 'Volume $code', weightKg: null),
      ],
      startLat: startLat,
      startLng: startLng,
    );
  }

  Future<void> clearCurrentManifest() async {
    state = state.copyWith(isLoading: true, errorMessage: null);
    try {
      await _repository.clearAllManifests();
      state = const ManifestState(isLoading: false);
      HapticFeedback.mediumImpact();
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        errorMessage: 'Falha ao limpar manifesto: ${e.toString()}',
      );
    }
  }
}

final manifestRepositoryProvider = Provider<ManifestRepository>((ref) {
  return ManifestRepository();
});

final manifestControllerProvider = StateNotifierProvider<ManifestNotifier, ManifestState>((ref) {
  final repo = ref.watch(manifestRepositoryProvider);
  return ManifestNotifier(repo);
});
