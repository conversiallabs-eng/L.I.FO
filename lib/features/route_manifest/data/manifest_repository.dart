import 'dart:convert';
import 'package:latlong2/latlong.dart';
import 'package:uuid/uuid.dart';
import '../../../core/database/app_database.dart';
import '../../../core/utils/lifo_calculator.dart';
import '../../../core/services/hybrid_routing_service.dart';
import '../../../core/services/manifest_import_service.dart';
import '../../../core/services/geocoding_service.dart';
import '../../../core/network/net_guard.dart';
import '../../../core/network/supabase_service.dart';
import '../domain/models/manifest_version.dart';
import '../domain/models/delivery_stop.dart';
import '../domain/models/package_item.dart';
import '../domain/models/spatial_slot.dart';

typedef RouteCalculation = ({
  ManifestVersion version,
  List<LatLng> polyline,
  bool isOnline,
  double distanceMeters,
  double durationSeconds,
  List<double> arrivalOffsets,
});

class NewPackageInput {
  final String barcode;
  final String description;
  final double? weightKg;

  const NewPackageInput({
    required this.barcode,
    required this.description,
    required this.weightKg,
  });
}

class ManifestRepository {
  final AppDatabase _db = AppDatabase.instance;
  final HybridRoutingService _routingService = HybridRoutingService();
  final GeocodingService _geocodingService = GeocodingService();
  final _uuid = const Uuid();

  Future<ManifestVersion?> getOrInitCurrentManifest() async {
    final cur = await _db.getCurrentVersion();
    if (cur != null) return cur;
    final all = await _db.getAllVersions();
    if (all.isNotEmpty) {
      await _db.setCurrentVersion(all.first.id);
      return await _db.getCurrentVersion();
    }
    return null;
  }

  Future<void> clearAllManifests() async {
    await _db.clearAllManifests();
  }

  Future<RouteCalculation> reoptimizeRoute(
    ManifestVersion currentVersion, {
    double? startLat,
    double? startLng,
  }) async {
    final root = await findRootManifest(currentVersion);
    final baseName = _extractBaseRouteName(root.label);

    final all = await _db.getAllVersions();
    final existingLabels = all.map((v) => v.label.trim().toLowerCase()).toSet();

    // Regra: Base ("Saco Grande") -> "Saco Grande Otimizada", "Saco Grande Otimizada 1", "Saco Grande Otimizada 2", etc.
    String nextLabel;
    if (!existingLabels.contains('$baseName Otimizada'.toLowerCase())) {
      nextLabel = '$baseName Otimizada';
    } else {
      int seq = 1;
      while (existingLabels.contains('$baseName Otimizada $seq'.toLowerCase())) {
        seq++;
      }
      nextLabel = '$baseName Otimizada $seq';
    }

    return _snapshotOptimized(
      baseStops: currentVersion.stops,
      rawList: _decodeRawList(currentVersion.rawData),
      nextIndex: currentVersion.versionIndex + 1,
      label: nextLabel,
      parentId: root.id,
      startLat: startLat,
      startLng: startLng,
    );
  }

  Future<RouteCalculation> addStop({
    required String recipientName,
    required String address,
    required double latitude,
    required double longitude,
    required List<NewPackageInput> packages,
    String? notes,
    double? startLat,
    double? startLng,
  }) async {
    final current = await _db.getCurrentVersion();

    final entry = <String, dynamic>{
      'recipient': recipientName,
      'address': address,
      'lat': latitude,
      'lng': longitude,
      'notes': notes,
      'packages': [
        for (final p in packages)
          {'barcode': p.barcode, 'desc': p.description, 'weight': p.weightKg},
      ],
    };
    final rawList = <Map<String, dynamic>>[
      if (current != null) ..._decodeRawList(current.rawData),
      entry,
    ];

    final stopId = _uuid.v4();
    final newStop = DeliveryStop(
      id: stopId,
      manifestVersionId: current?.id ?? 'pending',
      sequenceIndex: (current?.stops.length ?? 0) + 1,
      recipientName: recipientName,
      address: address,
      latitude: latitude,
      longitude: longitude,
      status: StopStatus.pending,
      notes: notes,
      spatialSlot: SpatialSlot.portaTraseira,
      packages: [
        for (final p in packages)
          PackageItem(
            id: _uuid.v4(),
            manifestVersionId: current?.id ?? 'pending',
            stopId: stopId,
            barcode: p.barcode,
            description: p.description,
            weightKg: p.weightKg,
            spatialSlot: SpatialSlot.portaTraseira,
            status: PackageStatus.pendingLoad,
          ),
      ],
    );

    final nextIndex = (current?.versionIndex ?? -1) + 1;
    return _snapshotOptimized(
      baseStops: [...?current?.stops, newStop],
      rawList: rawList,
      nextIndex: nextIndex,
      label: nextIndex == 0 ? 'Manifesto Original' : 'Rota Otimizada $nextIndex',
      parentId: current?.id,
      startLat: startLat,
      startLng: startLng,
    );
  }

  Future<RouteCalculation> importManifest({
    required String formatName,
    required List<ResolvedImportStop> stops,
    double? startLat,
    double? startLng,
  }) async {
    if (stops.isEmpty) {
      throw const ImportException('Nenhuma parada localizada para importar.');
    }
    final current = await _db.getCurrentVersion();

    final rawList = <Map<String, dynamic>>[
      for (final s in stops)
        {
          'recipient': s.recipient,
          'address': s.address,
          'lat': s.latitude,
          'lng': s.longitude,
          'orderRef': s.orderRef,
          'notes': s.notes,
          'packages': [
            for (final p in s.items)
              {'barcode': p.barcode, 'desc': p.description, 'weight': p.weightKg},
          ],
        },
    ];

    final baseStops = <DeliveryStop>[];
    for (final s in stops) {
      if (s.items.isEmpty) {
        final stopId = _uuid.v4();
        baseStops.add(
          DeliveryStop(
            id: stopId,
            manifestVersionId: current?.id ?? 'pending',
            sequenceIndex: baseStops.length + 1,
            recipientName: s.recipient,
            address: s.address,
            latitude: s.latitude,
            longitude: s.longitude,
            status: StopStatus.pending,
            notes: s.notes,
            spatialSlot: SpatialSlot.portaTraseira,
            packages: const [],
          ),
        );
      } else {
        // Padrão Circuit: cada pacote/volume é uma parada individual (1 pacote = 1 parada de entrega)
        for (final p in s.items) {
          final stopId = _uuid.v4();
          baseStops.add(
            DeliveryStop(
              id: stopId,
              manifestVersionId: current?.id ?? 'pending',
              sequenceIndex: baseStops.length + 1,
              recipientName: s.recipient,
              address: s.address,
              latitude: s.latitude,
              longitude: s.longitude,
              status: StopStatus.pending,
              notes: s.notes,
              spatialSlot: SpatialSlot.portaTraseira,
              packages: [
                PackageItem(
                  id: _uuid.v4(),
                  manifestVersionId: current?.id ?? 'pending',
                  stopId: stopId,
                  barcode: p.barcode,
                  description: p.description,
                  weightKg: p.weightKg,
                  spatialSlot: SpatialSlot.portaTraseira,
                  status: PackageStatus.pendingLoad,
                ),
              ],
            ),
          );
        }
      }
    }

    final baseLabel = formatName.trim().isEmpty ? 'Manifesto' : formatName.trim();
    final uniqueLabel = await generateUniqueLabel(baseLabel);
    return _snapshotOptimized(
      baseStops: baseStops,
      rawList: rawList,
      nextIndex: 0,
      label: uniqueLabel,
      parentId: null,
      startLat: startLat,
      startLng: startLng,
    );
  }

  Future<RouteCalculation> _snapshotOptimized({
    required List<DeliveryStop> baseStops,
    required List<Map<String, dynamic>> rawList,
    required int nextIndex,
    required String label,
    String? parentId,
    double? startLat,
    double? startLng,
  }) async {
    final newVersionId = _uuid.v4();
    final now = DateTime.now();

    // Separa paradas já finalizadas (entregues ou falhadas) de paradas pendentes
    final finishedStops = baseStops.where(
      (s) => s.status == StopStatus.completed || s.status == StopStatus.failed,
    ).toList();
    final pendingStops = baseStops.where(
      (s) => s.status == StopStatus.pending || s.status == StopStatus.inTransit,
    ).toList();

    // Se já existem paradas concluídas no passado, otimiza APENAS as pendentes a partir da posição atual
    final bool hasFinished = finishedStops.isNotEmpty && pendingStops.isNotEmpty;
    final stopsToOptimize = hasFinished ? pendingStops : baseStops;

    // Offline: ordem preservada, sem polyline, sem queimar timeouts OSRM.
    // (A geometria de rua será restaurada do banco em fetchGeometry.)
    final bool offline = await isOfflineFast();
    final routing = offline
        ? RoutingResult(
            // Ordem preservada; só os slots LIFO (sem cálculo de distância).
            stops: LifoCalculator.assignSlots(stopsToOptimize),
            polylinePoints: const [],
            isOnline: false,
            totalDistanceMeters: 0,
            totalDurationSeconds: 0,
            legDurationsSeconds: const [],
          )
        : await _routingService.optimizeAndRoute(
            rawStops: stopsToOptimize,
            startLat: startLat,
            startLng: startLng,
          );

    final List<DeliveryStop> newStops = [];

    // Mantém as paradas concluídas no histórico da rota com seus status preservados
    if (hasFinished) {
      for (final stop in finishedStops) {
        final newStopId = _uuid.v4();
        final slot = stop.spatialSlot;

        final updatedPkgs = stop.packages.map((p) {
          return p.copyWith(
            id: _uuid.v4(),
            manifestVersionId: newVersionId,
            stopId: newStopId,
            spatialSlot: slot,
          );
        }).toList();

        newStops.add(
          stop.copyWith(
            id: newStopId,
            manifestVersionId: newVersionId,
            packages: updatedPkgs,
          ),
        );
      }
    }

    // Adiciona as paradas pendentes com a rota otimizada a partir da localização atual
    for (int i = 0; i < routing.stops.length; i++) {
      final stop = routing.stops[i];
      final newStopId = _uuid.v4();
      final slot = stop.spatialSlot;

      final updatedPkgs = stop.packages.map((p) {
        return p.copyWith(
          id: _uuid.v4(),
          manifestVersionId: newVersionId,
          stopId: newStopId,
          spatialSlot: slot,
        );
      }).toList();

      newStops.add(
        stop.copyWith(
          id: newStopId,
          manifestVersionId: newVersionId,
          sequenceIndex: hasFinished ? (finishedStops.length + i + 1) : stop.sequenceIndex,
          packages: updatedPkgs,
        ),
      );
    }

    final totalPkgs = newStops.fold(0, (acc, s) => acc + s.packages.length);

    final newVersion = ManifestVersion(
      id: newVersionId,
      versionIndex: nextIndex,
      label: label,
      parentVersionId: parentId,
      rawData: jsonEncode(rawList),
      createdAt: now,
      isCurrent: true,
      totalStops: newStops.length,
      totalPackages: totalPkgs,
      stops: newStops,
    );

    await _db.saveManifestVersion(newVersion);
    SupabaseService.instance.pushManifestVersion(newVersion);

    // Geometria de rua persistida: reabrir offline mostra o traçado real.
    var outPolyline = routing.polylinePoints;
    var outDistance = routing.totalDistanceMeters;
    var outDuration = routing.totalDurationSeconds;
    if (routing.isOnline && routing.polylinePoints.isNotEmpty) {
      try {
        await _db.saveRouteGeometry(
          versionId: newVersionId,
          encodedPolyline: AppDatabase.encodePolyline([
            for (final p in routing.polylinePoints)
              {'lat': p.latitude, 'lng': p.longitude},
          ]),
          distanceMeters: routing.totalDistanceMeters,
          durationSeconds: routing.totalDurationSeconds,
        );
      } catch (_) {}
    } else if (routing.polylinePoints.isEmpty) {
      // Versão nascida offline (ex.: parada adicionada sem rede): herda a
      // última rua salva da versão de origem em vez de nascer sem linha.
      // A ordem offline é preservada, então a geometria segue válida
      // (para parada nova, falta só o trechinho dela — marcadores mostram).
      try {
        final sourceId = parentId ??
            (baseStops.isNotEmpty
                ? baseStops.first.manifestVersionId
                : null);
        final inherited = sourceId == null
            ? null
            : await _db.getRouteGeometry(sourceId);
        final pts =
            AppDatabase.decodePolyline(inherited?['road_polyline'] as String?);
        if (pts.isNotEmpty) {
          await _db.saveRouteGeometry(
            versionId: newVersionId,
            encodedPolyline: inherited!['road_polyline'] as String,
            distanceMeters:
                (inherited['road_distance_m'] as num?)?.toDouble() ?? 0,
            durationSeconds:
                (inherited['road_duration_s'] as num?)?.toDouble() ?? 0,
          );
          outPolyline = [
            for (final p in pts) LatLng(p['lat']!, p['lng']!),
          ];
          outDistance =
              (inherited['road_distance_m'] as num?)?.toDouble() ?? 0;
          outDuration =
              (inherited['road_duration_s'] as num?)?.toDouble() ?? 0;
        }
      } catch (_) {}
    }

    return (
      version: newVersion,
      polyline: outPolyline,
      isOnline: routing.isOnline,
      distanceMeters: outDistance,
      durationSeconds: outDuration,
      arrivalOffsets: RoutingResult.arrivalOffsets(
        legDurations: routing.legDurationsSeconds,
        stopCount: newStops.length,
        hasStart: startLat != null && startLng != null,
      ),
    );
  }

  Future<RoutingResult> fetchGeometry(
    List<DeliveryStop> stops, {
    double? startLat,
    double? startLng,
  }) async {
    // Traça rota viária APENAS das paradas pendentes (não volta nas paradas já entregues)
    final pending = stops.where(
      (s) => s.status == StopStatus.pending || s.status == StopStatus.inTransit,
    ).toList();
    final targetStops = pending.isNotEmpty ? pending : stops;

    // Rua salva primeiro: instantâneo e evita recomputar a rota inteira
    // no OSRM a cada delete/boot/conclusão (era essa a demora ao excluir —
    // 83 paradas × chunks de 25 com timeout de 10s por servidor).
    // O refresh de rua acontece no "Otimizar" explícito, que persiste.
    final stored = await _storedGeometry(targetStops);
    if (stored != null) return stored;

    // Offline sem rua salva: vazio honesto, sem queimar timeouts OSRM.
    if (await isOfflineFast()) {
      return RoutingResult(
        stops: targetStops,
        polylinePoints: const [],
        isOnline: false,
        totalDistanceMeters: 0,
        totalDurationSeconds: 0,
        legDurationsSeconds: const [],
      );
    }

    final routing = await _routingService.fetchGeometryOnly(
      stops: targetStops,
      startLat: startLat,
      startLng: startLng,
    );
    if (routing.polylinePoints.isNotEmpty) {
      // Online: persiste para o próximo boot offline.
      try {
        await _db.saveRouteGeometry(
          versionId: targetStops.first.manifestVersionId,
          encodedPolyline: AppDatabase.encodePolyline([
            for (final p in routing.polylinePoints)
              {'lat': p.latitude, 'lng': p.longitude},
          ]),
          distanceMeters: routing.totalDistanceMeters,
          durationSeconds: routing.totalDurationSeconds,
        );
      } catch (_) {}
      return routing;
    }

    // Sem rua na rede nem no banco: vazio — nunca reta.
    return routing;
  }

  /// Última geometria de rua salva no banco para a versão dessas paradas.
  /// Null quando nunca houve cálculo online.
  Future<RoutingResult?> _storedGeometry(List<DeliveryStop> targetStops) async {
    if (targetStops.isEmpty) return null;
    try {
      final stored =
          await _db.getRouteGeometry(targetStops.first.manifestVersionId);
      if (stored == null) return null;
      final pts =
          AppDatabase.decodePolyline(stored['road_polyline'] as String?);
      if (pts.isEmpty) return null;
      return RoutingResult(
        stops: targetStops,
        polylinePoints: [
          for (final p in pts) LatLng(p['lat']!, p['lng']!),
        ],
        isOnline: false,
        totalDistanceMeters:
            (stored['road_distance_m'] as num?)?.toDouble() ?? 0,
        totalDurationSeconds:
            (stored['road_duration_s'] as num?)?.toDouble() ?? 0,
        legDurationsSeconds: const [],
      );
    } catch (_) {
      return null;
    }
  }

  List<Map<String, dynamic>> _decodeRawList(String rawData) {
    try {
      final decoded = jsonDecode(rawData) as List<dynamic>;
      return decoded.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } catch (_) {
      return [];
    }
  }

  Future<ManifestVersion> revertToVersion(String targetVersionId) async {
    await _db.setCurrentVersion(targetVersionId);
    final restored = await _db.getCurrentVersion();
    if (restored == null) {
      throw Exception('Falha ao restaurar versao de manifesto selecionada.');
    }
    return restored;
  }

  Future<List<ManifestVersion>> getVersionHistory() async {
    return await _db.getAllVersions();
  }

  Future<Map<String, dynamic>?> lookupBarcode(String barcode) async {
    return await _db.findPackageAndStopByBarcode(barcode);
  }

  Future<bool> markPackageLoaded(String barcode) async {
    return await _db.markPackageLoaded(barcode);
  }

  /// Vincula um barcode escaneado como novo pacote de uma parada existente.
  /// Usa o spatial_slot da parada como slot do pacote e marca como já carregado.
  Future<void> addPackageToExistingStop({
    required String stopId,
    required String barcode,
    required String description,
    required double? weightKg,
  }) async {
    final current = await _db.getCurrentVersion();
    if (current == null) throw Exception('Nenhum manifesto ativo.');

    // Encontra a parada para pegar o spatial_slot e manifestVersionId
    final stop = current.stops.firstWhere(
      (s) => s.id == stopId,
      orElse: () => throw Exception('Parada $stopId não encontrada.'),
    );

    await _db.insertPackageForStop(
      packageId: _uuid.v4(),
      manifestVersionId: current.id,
      stopId: stopId,
      barcode: barcode,
      description: description,
      weightKg: weightKg,
      spatialSlot: stop.spatialSlot.label,
    );
  }

  Future<void> updateStopStatus(String stopId, StopStatus status) async {
    await _db.updateStopStatus(stopId, status);
  }

  Future<void> updatePackageStatus(String packageId, PackageStatus status) async {
    await _db.updatePackageStatus(packageId, status);
  }

  /// Atribui um pacote (barcode) a um compartimento do baú, marcando como
  /// carregado. Retorna o pacote atualizado ou null se não achou no manifesto.
  Future<PackageItem?> assignPackageToSlot({
    required String barcode,
    required SpatialSlot slot,
  }) async {
    final current = await _db.getCurrentVersion();
    if (current == null) return null;
    final code = barcode.trim().toUpperCase();
    PackageItem? found;
    for (final stop in current.stops) {
      for (final pkg in stop.packages) {
        if (pkg.barcode.trim().toUpperCase() == code) {
          found = pkg;
          break;
        }
      }
      if (found != null) break;
    }
    if (found == null) return null;
    final ok = await _db.assignPackageToSlot(
      packageId: found.id,
      spatialSlotLabel: slot.label,
    );
    if (!ok) return null;
    return found.copyWith(
      spatialSlot: slot,
      status: PackageStatus.loaded,
      scannedAt: DateTime.now(),
      slotUserAssigned: true,
    );
  }

  /// Desfaz a atribuição manual de compartimento de um volume: ele volta ao
  /// compartimento automático do LIFO e o local some dos cards de rota.
  /// O status de carga é preservado. Usado no "X" do painel do baú.
  Future<bool> unassignPackageFromSlot(String barcode) async {
    final current = await _db.getCurrentVersion();
    if (current == null) return false;
    final code = barcode.trim().toUpperCase();
    final totalStops = current.stops.length;
    for (final stop in current.stops) {
      for (final pkg in stop.packages) {
        if (pkg.barcode.trim().toUpperCase() == code) {
          final autoSlot =
              SpatialSlot.slotForDeliverySequence(stop.sequenceIndex, totalStops);
          return _db.clearPackageSlot(
            packageId: pkg.id,
            autoSlotLabel: autoSlot.label,
          );
        }
      }
    }
    return false;
  }

  Future<void> updateVersionLabel(String versionId, String newLabel) async {
    await _db.database.then((db) => db.rawUpdate(
      'UPDATE manifest_versions SET label = ? WHERE id = ?',
      [newLabel, versionId],
    ));
  }

  Future<ManifestVersion> findRootManifest(ManifestVersion current) async {
    var curr = current;
    final all = await _db.getAllVersions();
    final map = {for (final item in all) item.id: item};
    final visited = <String>{curr.id};
    while (curr.parentVersionId != null && map.containsKey(curr.parentVersionId)) {
      final parent = map[curr.parentVersionId!]!;
      if (visited.contains(parent.id)) break;
      visited.add(parent.id);
      curr = parent;
    }
    return curr;
  }

  String _extractBaseRouteName(String label) {
    var clean = label.trim();
    clean = clean.replaceAll(RegExp(r'\s+Otimizada(\s+\d+)?$', caseSensitive: false), '').trim();
    if (clean.isEmpty) return 'Rota';
    return clean;
  }

  Future<String> generateUniqueLabel(String desiredName, {String? excludeId}) async {
    final all = await _db.getAllVersions();
    final existingNames = <String>{};
    for (final v in all) {
      if (excludeId != null && v.id == excludeId) continue;
      existingNames.add(v.label.trim().toLowerCase());
    }

    final trimmed = desiredName.trim();
    if (!existingNames.contains(trimmed.toLowerCase())) {
      return trimmed;
    }

    int counter = 1;
    while (true) {
      final candidate = '$trimmed $counter';
      if (!existingNames.contains(candidate.toLowerCase())) {
        return candidate;
      }
      counter++;
    }
  }

  Future<void> deleteVersion(String versionId) async {
    final current = await _db.getCurrentVersion();
    await _db.deleteManifestVersion(versionId);

    if (current?.id == versionId) {
      final remaining = await _db.getAllVersions();
      if (remaining.isNotEmpty) {
        await _db.setCurrentVersion(remaining.first.id);
      }
    }
  }

  Future<void> deleteManifestCascade(String rootManifestId) async {
    final all = await _db.getAllVersions();
    final toDeleteIds = <String>{rootManifestId};
    bool added = true;
    while (added) {
      added = false;
      for (final v in all) {
        if (v.parentVersionId != null && toDeleteIds.contains(v.parentVersionId) && !toDeleteIds.contains(v.id)) {
          toDeleteIds.add(v.id);
          added = true;
        }
      }
    }

    final current = await _db.getCurrentVersion();
    final bool currentWasDeleted = current != null && toDeleteIds.contains(current.id);

    await _db.deleteManifestVersions(toDeleteIds.toList());

    if (currentWasDeleted) {
      final remaining = await _db.getAllVersions();
      if (remaining.isNotEmpty) {
        await _db.setCurrentVersion(remaining.first.id);
      }
    }
  }


  /// Atualiza o endereço de uma parada, geocodifica se necessário e recalcula
  /// a rota reotimizando todas as paradas pendentes.
  /// NÃO cria nova versão — atualiza a versão atual in-place.
  Future<RouteCalculation> updateStopAddressAndReoptimize({
    required String stopId,
    required String newAddress,
    double? newLat,
    double? newLng,
    double? startLat,
    double? startLng,
  }) async {
    final current = await _db.getCurrentVersion();
    if (current == null) {
      throw Exception('Nenhum manifesto ativo para atualizar endereço.');
    }

    double lat = newLat ?? 0;
    double lng = newLng ?? 0;
    if (lat == 0 || lng == 0) {
      final geoResults = await _geocodingService.searchAddress(newAddress);
      if (geoResults.isNotEmpty) {
        lat = geoResults.first.latitude;
        lng = geoResults.first.longitude;
      }
    }

    // Atualiza no banco de dados local
    await _db.updateStopAddress(
      stopId: stopId,
      address: newAddress,
      latitude: lat != 0 ? lat : null,
      longitude: lng != 0 ? lng : null,
    );

    // Leitura atualizada após persistência
    final updatedCurrent = await _db.getCurrentVersion() ?? current;

    // Recalcula traçado sem criar nova versão
    final pendingStops = updatedCurrent.stops.where(
      (s) => s.status == StopStatus.pending || s.status == StopStatus.inTransit,
    ).toList();
    final stopsToRoute = pendingStops.isNotEmpty ? pendingStops : updatedCurrent.stops;

    // Offline: edição salva local; a rua antiga não vale para o novo
    // endereço — volta vazio (nunca reta, nunca rua stale) até a rede voltar.
    if (await isOfflineFast()) {
      return (
        version: updatedCurrent,
        polyline: <LatLng>[],
        isOnline: false,
        distanceMeters: 0.0,
        durationSeconds: 0.0,
        arrivalOffsets: <double>[],
      );
    }

    final routing = await _routingService.optimizeAndRoute(
      rawStops: stopsToRoute,
      startLat: startLat,
      startLng: startLng,
    );

    // Online: atualiza a rua salva (a versão é a mesma, in-place).
    if (routing.isOnline && routing.polylinePoints.isNotEmpty) {
      try {
        await _db.saveRouteGeometry(
          versionId: updatedCurrent.id,
          encodedPolyline: AppDatabase.encodePolyline([
            for (final p in routing.polylinePoints)
              {'lat': p.latitude, 'lng': p.longitude},
          ]),
          distanceMeters: routing.totalDistanceMeters,
          durationSeconds: routing.totalDurationSeconds,
        );
      } catch (_) {}
    }

    return (
      version: updatedCurrent,
      polyline: routing.polylinePoints,
      isOnline: routing.isOnline,
      distanceMeters: routing.totalDistanceMeters,
      durationSeconds: routing.totalDurationSeconds,
      arrivalOffsets: RoutingResult.arrivalOffsets(
        legDurations: routing.legDurationsSeconds,
        stopCount: updatedCurrent.stops.length,
        hasStart: startLat != null && startLng != null,
      ),
    );
  }

  Future<RouteCalculation> removeStop({
    required String stopId,
    double? startLat,
    double? startLng,
  }) async {
    final current = await _db.getCurrentVersion();
    if (current == null) {
      throw Exception('Nenhum manifesto ativo para remover parada.');
    }

    // Remove a parada do banco (in-place na versão atual — sem criar nova versão)
    await _db.deleteStop(stopId);

    // Lê o estado atualizado
    final updatedCurrent = await _db.getCurrentVersion();
    final remaining = updatedCurrent?.stops ?? [];

    if (remaining.isEmpty) {
      return (
        version: updatedCurrent ?? current,
        polyline: <LatLng>[],
        isOnline: false,
        distanceMeters: 0.0,
        durationSeconds: 0.0,
        arrivalOffsets: <double>[],
      );
    }

    // Recalcula traçado das paradas restantes sem criar nova versão
    final pending = remaining.where(
      (s) => s.status == StopStatus.pending || s.status == StopStatus.inTransit,
    ).toList();
    final stopsToRoute = pending.isNotEmpty ? pending : remaining;

    // Offline: sem rede não há traçado novo — vazio honesto até reconectar.
    if (await isOfflineFast()) {
      return (
        version: updatedCurrent ?? current,
        polyline: <LatLng>[],
        isOnline: false,
        distanceMeters: 0.0,
        durationSeconds: 0.0,
        arrivalOffsets: RoutingResult.arrivalOffsets(
          legDurations: const [],
          stopCount: remaining.length,
          hasStart: startLat != null && startLng != null,
        ),
      );
    }

    final routing = await _routingService.fetchGeometryOnly(
      stops: stopsToRoute,
      startLat: startLat,
      startLng: startLng,
    );

    // Online: atualiza a rua salva (versão in-place).
    if (routing.isOnline && routing.polylinePoints.isNotEmpty) {
      try {
        await _db.saveRouteGeometry(
          versionId: (updatedCurrent ?? current).id,
          encodedPolyline: AppDatabase.encodePolyline([
            for (final p in routing.polylinePoints)
              {'lat': p.latitude, 'lng': p.longitude},
          ]),
          distanceMeters: routing.totalDistanceMeters,
          durationSeconds: routing.totalDurationSeconds,
        );
      } catch (_) {}
    }

    return (
      version: updatedCurrent ?? current,
      polyline: routing.polylinePoints,
      isOnline: routing.isOnline,
      distanceMeters: routing.totalDistanceMeters,
      durationSeconds: routing.totalDurationSeconds,
      arrivalOffsets: RoutingResult.arrivalOffsets(
        legDurations: routing.legDurationsSeconds,
        stopCount: remaining.length,
        hasStart: startLat != null && startLng != null,
      ),
    );
  }
}
