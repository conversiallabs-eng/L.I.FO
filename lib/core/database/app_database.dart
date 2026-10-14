import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../../features/route_manifest/domain/models/manifest_version.dart';
import '../../features/route_manifest/domain/models/delivery_stop.dart';
import '../../features/route_manifest/domain/models/package_item.dart';
import '../../features/auth/domain/models/user_profile.dart';

class AppDatabase {
  static final AppDatabase instance = AppDatabase._internal();
  AppDatabase._internal();

  Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDatabase();
    return _db!;
  }

  Future<Database> _initDatabase() async {
    if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'lifo_logistics.db');

    return await openDatabase(
      path,
      version: 4,
      onCreate: _onCreate,
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          // v2: apaga o manifesto mockado do seed inicial (paradas fake de SP).
          // O app recomeça vazio — só entra dado real cadastrado.
          await db.delete('package_items');
          await db.delete('delivery_stops');
          await db.delete('manifest_versions');
          await db.delete('sync_queue');
        }
        if (oldVersion < 3) {
          await _createUserProfilesTable(db);
        }
        if (oldVersion < 4) {
          // v4: coluna cidade/UF no perfil.
          try {
            await db.execute('ALTER TABLE user_profiles ADD COLUMN city_uf TEXT');
          } catch (_) {}
        }
      },
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE manifest_versions (
        id TEXT PRIMARY KEY,
        version_index INTEGER NOT NULL,
        label TEXT NOT NULL,
        parent_version_id TEXT,
        raw_data TEXT NOT NULL,
        created_at TEXT NOT NULL,
        is_current INTEGER NOT NULL,
        total_stops INTEGER NOT NULL,
        total_packages INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE delivery_stops (
        id TEXT PRIMARY KEY,
        manifest_version_id TEXT NOT NULL,
        sequence_index INTEGER NOT NULL,
        recipient_name TEXT NOT NULL,
        address TEXT NOT NULL,
        latitude REAL NOT NULL,
        longitude REAL NOT NULL,
        status TEXT NOT NULL,
        spatial_slot TEXT NOT NULL,
        time_window TEXT,
        notes TEXT,
        FOREIGN KEY (manifest_version_id) REFERENCES manifest_versions (id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE TABLE package_items (
        id TEXT PRIMARY KEY,
        manifest_version_id TEXT NOT NULL,
        stop_id TEXT NOT NULL,
        barcode TEXT NOT NULL,
        description TEXT NOT NULL,
        weight_kg REAL NOT NULL,
        volume_m3 REAL NOT NULL,
        spatial_slot TEXT NOT NULL,
        status TEXT NOT NULL,
        scanned_at TEXT,
        FOREIGN KEY (manifest_version_id) REFERENCES manifest_versions (id) ON DELETE CASCADE,
        FOREIGN KEY (stop_id) REFERENCES delivery_stops (id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_packages_barcode ON package_items(barcode);
    ''');

    await db.execute('''
      CREATE TABLE sync_queue (
        id TEXT PRIMARY KEY,
        entity_type TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        action TEXT NOT NULL,
        payload TEXT NOT NULL,
        created_at TEXT NOT NULL,
        synced INTEGER NOT NULL
      )
    ''');

    await _createUserProfilesTable(db);
  }

  Future<void> _createUserProfilesTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS user_profiles (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        email TEXT NOT NULL,
        plan TEXT NOT NULL,
        expires_at TEXT NOT NULL,
        avatar_url TEXT,
        vehicle_type TEXT,
        is_logged_in INTEGER NOT NULL,
        is_google_auth INTEGER NOT NULL,
        cpf TEXT,
        rg TEXT,
        phone TEXT,
        billing_address TEXT,
        billing_cep TEXT,
        city_uf TEXT,
        fcm_token TEXT,
        updated_at TEXT NOT NULL
      )
    ''');
  }

  Future<void> saveUserProfile(UserProfile profile) async {
    final db = await database;
    await _createUserProfilesTable(db);
    await db.insert(
      'user_profiles',
      {
        'id': profile.id,
        'name': profile.name,
        'email': profile.email,
        'plan': profile.plan,
        'expires_at': profile.expiresAt.toIso8601String(),
        'avatar_url': profile.avatarUrl,
        'vehicle_type': profile.vehicleType,
        'is_logged_in': profile.isLoggedIn ? 1 : 0,
        'is_google_auth': profile.isGoogleAuth ? 1 : 0,
        'cpf': profile.cpf,
        'rg': profile.rg,
        'phone': profile.phone,
        'billing_address': profile.billingAddress,
        'billing_cep': profile.billingCep,
        'city_uf': profile.cityUf,
        'fcm_token': profile.fcmToken,
        'updated_at': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<UserProfile?> getUserProfile() async {
    final db = await database;
    await _createUserProfilesTable(db);
    final rows = await db.query('user_profiles', limit: 1, orderBy: 'updated_at DESC');
    if (rows.isEmpty) return null;
    final r = rows.first;
    return UserProfile(
      id: r['id'] as String,
      name: r['name'] as String,
      email: r['email'] as String,
      plan: r['plan'] as String? ?? 'Standard',
      expiresAt: DateTime.tryParse(r['expires_at'] as String? ?? '') ?? DateTime(2026, 10, 17),
      avatarUrl: r['avatar_url'] as String?,
      vehicleType: r['vehicle_type'] as String? ?? 'Van de Carga',
      isLoggedIn: (r['is_logged_in'] as int? ?? 1) == 1,
      isGoogleAuth: (r['is_google_auth'] as int? ?? 1) == 1,
      cpf: r['cpf'] as String?,
      rg: r['rg'] as String?,
      phone: r['phone'] as String?,
      billingAddress: r['billing_address'] as String?,
      billingCep: r['billing_cep'] as String?,
      cityUf: r.containsKey('city_uf') ? r['city_uf'] as String? : null,
      fcmToken: r['fcm_token'] as String?,
    );
  }

  Future<void> clearUserProfile() async {
    final db = await database;
    await _createUserProfilesTable(db);
    await db.delete('user_profiles');
  }

  // Immutable versioning: save new version with stops and packages
  Future<void> saveManifestVersion(ManifestVersion version) async {
    final db = await database;
    await db.transaction((txn) async {
      if (version.isCurrent) {
        await txn.update(
          'manifest_versions',
          {'is_current': 0},
        );
      }

      await txn.insert(
        'manifest_versions',
        version.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      for (final stop in version.stops) {
        await txn.insert(
          'delivery_stops',
          stop.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );

        for (final pkg in stop.packages) {
          await txn.insert(
            'package_items',
            pkg.toMap(),
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      }
    });
  }

  // Returns all manifest versions in history tree (descending by index)
  Future<List<ManifestVersion>> getAllVersions() async {
    final db = await database;
    final List<Map<String, dynamic>> rows = await db.query(
      'manifest_versions',
      orderBy: 'version_index DESC',
    );

    return rows.map((r) => ManifestVersion.fromMap(r)).toList();
  }

  // Returns current active version populated with stops and packages
  Future<ManifestVersion?> getCurrentVersion() async {
    final db = await database;
    final List<Map<String, dynamic>> versionRows = await db.query(
      'manifest_versions',
      where: 'is_current = ?',
      whereArgs: [1],
      limit: 1,
    );

    if (versionRows.isEmpty) return null;
    final versionMap = versionRows.first;
    final versionId = versionMap['id'] as String;

    final List<Map<String, dynamic>> stopRows = await db.query(
      'delivery_stops',
      where: 'manifest_version_id = ?',
      whereArgs: [versionId],
      orderBy: 'sequence_index ASC',
    );

    final List<DeliveryStop> stops = [];
    for (final sRow in stopRows) {
      final stopId = sRow['id'] as String;
      final List<Map<String, dynamic>> pkgRows = await db.query(
        'package_items',
        where: 'stop_id = ?',
        whereArgs: [stopId],
      );

      final packages = pkgRows.map((p) => PackageItem.fromMap(p)).toList();
      stops.add(DeliveryStop.fromMap(sRow, packages: packages));
    }

    return ManifestVersion.fromMap(versionMap, stops: stops);
  }

  // Reverts active manifest to a specific version without deleting history
  Future<void> setCurrentVersion(String targetVersionId) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.update('manifest_versions', {'is_current': 0});
      await txn.update(
        'manifest_versions',
        {'is_current': 1},
        where: 'id = ?',
        whereArgs: [targetVersionId],
      );
    });
  }

  // Deleta uma versão específica e seus dados associados
  Future<void> deleteManifestVersion(String versionId) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('package_items', where: 'manifest_version_id = ?', whereArgs: [versionId]);
      await txn.delete('delivery_stops', where: 'manifest_version_id = ?', whereArgs: [versionId]);
      await txn.delete('manifest_versions', where: 'id = ?', whereArgs: [versionId]);
    });
  }

  // Deleta um grupo de versões em lote (cascata)
  Future<void> deleteManifestVersions(List<String> versionIds) async {
    if (versionIds.isEmpty) return;
    final db = await database;
    await db.transaction((txn) async {
      final placeholders = List.filled(versionIds.length, '?').join(',');
      await txn.delete('package_items', where: 'manifest_version_id IN ($placeholders)', whereArgs: versionIds);
      await txn.delete('delivery_stops', where: 'manifest_version_id IN ($placeholders)', whereArgs: versionIds);
      await txn.delete('manifest_versions', where: 'id IN ($placeholders)', whereArgs: versionIds);
    });
  }

  // Retorna uma versão específica por ID
  Future<ManifestVersion?> getVersionById(String versionId) async {
    final db = await database;
    final rows = await db.query(
      'manifest_versions',
      where: 'id = ?',
      whereArgs: [versionId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return ManifestVersion.fromMap(rows.first);
  }

  // Limpa completamente todos os manifestos e paradas para permitir início limpo
  Future<void> clearAllManifests() async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('package_items');
      await txn.delete('delivery_stops');
      await txn.delete('manifest_versions');
      await txn.delete('sync_queue');
    });
  }

  // Instant scanner mapping: look up package by barcode within the current manifest version
  Future<Map<String, dynamic>?> findPackageAndStopByBarcode(String barcode) async {
    final db = await database;
    final current = await getCurrentVersion();
    if (current == null) return null;

    final List<Map<String, dynamic>> pkgRows = await db.query(
      'package_items',
      where: 'barcode = ? AND manifest_version_id = ?',
      whereArgs: [barcode.trim(), current.id],
      limit: 1,
    );

    if (pkgRows.isEmpty) return null;

    final pkgMap = pkgRows.first;
    final stopId = pkgMap['stop_id'] as String;

    final List<Map<String, dynamic>> stopRows = await db.query(
      'delivery_stops',
      where: 'id = ?',
      whereArgs: [stopId],
      limit: 1,
    );

    if (stopRows.isEmpty) return null;

    return {
      'package': PackageItem.fromMap(pkgMap),
      'stop': DeliveryStop.fromMap(stopRows.first),
    };
  }

  // Updates status of scanned package directly in DB
  Future<bool> markPackageLoaded(String barcode) async {
    final db = await database;
    final current = await getCurrentVersion();
    if (current == null) return false;

    final count = await db.update(
      'package_items',
      {
        'status': PackageStatus.loaded.name,
        'scanned_at': DateTime.now().toIso8601String(),
      },
      where: 'barcode = ? AND manifest_version_id = ?',
      whereArgs: [barcode.trim(), current.id],
    );

    return count > 0;
  }

  /// Move um pacote para um compartimento do baú (bipagem por quadrado).
  /// Marca como carregado junto — bipar é carregar.
  Future<bool> assignPackageToSlot({
    required String packageId,
    required String spatialSlotLabel,
    bool markLoaded = true,
  }) async {
    final db = await database;
    final values = <String, Object?>{
      'spatial_slot': spatialSlotLabel,
    };
    if (markLoaded) {
      values['status'] = PackageStatus.loaded.name;
      values['scanned_at'] = DateTime.now().toIso8601String();
    }
    final count = await db.update(
      'package_items',
      values,
      where: 'id = ?',
      whereArgs: [packageId],
    );
    return count > 0;
  }

  // Inserts a new package directly into an existing stop (for scanner-based linking)
  Future<void> insertPackageForStop({
    required String packageId,
    required String manifestVersionId,
    required String stopId,
    required String barcode,
    required String description,
    required double weightKg,
    required String spatialSlot,
  }) async {
    final db = await database;
    await db.insert(
      'package_items',
      {
        'id': packageId,
        'manifest_version_id': manifestVersionId,
        'stop_id': stopId,
        'barcode': barcode,
        'description': description,
        'weight_kg': weightKg,
        'volume_m3': 0.05,
        'spatial_slot': spatialSlot,
        'status': PackageStatus.loaded.name,  // já bipeado pelo scanner
        'scanned_at': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // Updates delivery stop status (e.g. completed, in transit)
  Future<void> updateStopStatus(String stopId, StopStatus status) async {
    final db = await database;
    await db.update(
      'delivery_stops',
      {'status': status.name},
      where: 'id = ?',
      whereArgs: [stopId],
    );
  }

  // Updates delivery stop address and optional coordinates
  Future<void> updateStopAddress({
    required String stopId,
    required String address,
    double? latitude,
    double? longitude,
  }) async {
    final db = await database;
    final Map<String, dynamic> values = {'address': address};
    if (latitude != null) values['latitude'] = latitude;
    if (longitude != null) values['longitude'] = longitude;
    await db.update(
      'delivery_stops',
      values,
      where: 'id = ?',
      whereArgs: [stopId],
    );
  }

  /// Remove uma parada (e seus pacotes via CASCADE) diretamente da versão atual,
  /// sem criar uma nova versão no histórico.
  Future<void> deleteStop(String stopId) async {
    final db = await database;
    await db.transaction((txn) async {
      // Pega o manifest_version_id antes de deletar
      final stopRows = await txn.query(
        'delivery_stops',
        columns: ['manifest_version_id'],
        where: 'id = ?',
        whereArgs: [stopId],
        limit: 1,
      );
      if (stopRows.isEmpty) return;
      final versionId = stopRows.first['manifest_version_id'] as String;

      // Deleta pacotes e parada
      await txn.delete('package_items', where: 'stop_id = ?', whereArgs: [stopId]);
      await txn.delete('delivery_stops', where: 'id = ?', whereArgs: [stopId]);

      // Atualiza contadores na versão
      final remainingStops = await txn.query(
        'delivery_stops',
        columns: ['id'],
        where: 'manifest_version_id = ?',
        whereArgs: [versionId],
      );
      final remainingPkgs = await txn.query(
        'package_items',
        columns: ['id'],
        where: 'manifest_version_id = ?',
        whereArgs: [versionId],
      );
      await txn.update(
        'manifest_versions',
        {
          'total_stops': remainingStops.length,
          'total_packages': remainingPkgs.length,
        },
        where: 'id = ?',
        whereArgs: [versionId],
      );
    });
  }

  // Sync Queue methods for offline-first resilience
  Future<void> enqueueSync({
    required String id,
    required String entityType,
    required String entityId,
    required String action,
    required Map<String, dynamic> payload,
  }) async {
    final db = await database;
    await db.insert('sync_queue', {
      'id': id,
      'entity_type': entityType,
      'entity_id': entityId,
      'action': action,
      'payload': jsonEncode(payload),
      'created_at': DateTime.now().toIso8601String(),
      'synced': 0,
    });
  }

  Future<List<Map<String, dynamic>>> getPendingSyncQueue() async {
    final db = await database;
    return await db.query('sync_queue', where: 'synced = ?', whereArgs: [0], orderBy: 'created_at ASC');
  }

  Future<void> markQueueItemSynced(String id) async {
    final db = await database;
    await db.update('sync_queue', {'synced': 1}, where: 'id = ?', whereArgs: [id]);
  }
}
