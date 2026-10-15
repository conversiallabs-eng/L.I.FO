import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:lifo/core/layout/map_split_layout.dart';
import 'package:lifo/core/map/map_tiles.dart';
import 'package:lifo/core/services/hybrid_routing_service.dart';
import 'package:lifo/core/services/manifest_import_service.dart';
import 'package:lifo/core/utils/lifo_calculator.dart';
import 'package:lifo/core/models/route_step.dart';
import 'package:lifo/features/navigation_map/presentation/widgets/logistics_map_canvas.dart';
import 'package:lifo/features/route_manifest/domain/models/delivery_stop.dart';
import 'package:lifo/features/route_manifest/domain/models/package_item.dart';
import 'package:lifo/features/route_manifest/domain/models/spatial_slot.dart';
import 'package:lifo/features/route_manifest/domain/models/manifest_version.dart';
import 'package:lifo/core/utils/route_simplify.dart';
import 'package:lifo/core/services/app_headers_service.dart';
import 'package:lifo/core/services/app_update_service.dart';

void main() {
  group('Map Gesture Tests', () {
    // Giro por dedo liberado (pedido de uso em campo): `InteractiveFlag.all`
    // permite pinça com torção girar a câmera. O zoom precisa continuar
    // funcionando; a rotação por código (moveAndRotate do course-up) não é
    // afetada por InteractiveFlag.
    Future<MapController> pumpMap(WidgetTester tester) async {
      final controller = MapController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 400,
              height: 400,
              child: LogisticsMapCanvas(
                mapController: controller,
                initialCenter: const LatLng(-27.6, -48.5),
                initialZoom: 13,
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      return controller;
    }

    testWidgets('Pinch com torção gira o mapa (giro por dedo liberado)',
        (tester) async {
      final controller = await pumpMap(tester);
      final before = controller.camera;
      expect(before.rotation, 0);

      // Dedos afastando E torcendo: com o giro liberado, este gesto gira.
      final g1 = await tester.startGesture(const Offset(170, 200));
      final g2 = await tester.startGesture(const Offset(230, 200));
      for (var i = 0; i < 8; i++) {
        await g1.moveBy(const Offset(-6, 8));
        await g2.moveBy(const Offset(6, -8));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g1.up();
      await g2.up();
      await tester.pump(const Duration(milliseconds: 50));

      expect(
        controller.camera.rotation.abs(),
        greaterThan(5),
        reason: 'pinch com torção tem que girar a câmera',
      );
      expect(
        controller.camera.zoom,
        greaterThan(before.zoom),
        reason: 'o zoom por pinch tem que continuar funcionando',
      );
    });

    testWidgets('Rotação por código (course-up) continua funcionando',
        (tester) async {
      final controller = await pumpMap(tester);
      expect(controller.camera.rotation, 0);

      // É assim que o modo course-up gira o mapa: pelo controller, não por
      // gesto. O flag de interação não pode quebrar isso.
      controller.moveAndRotate(const LatLng(-27.6, -48.5), 15, 45);
      await tester.pump(const Duration(milliseconds: 50));

      expect(controller.camera.rotation, closeTo(45, 0.01));
      expect(controller.camera.zoom, closeTo(15, 0.01));
    });

    testWidgets('Pinch reto também gira 0 e dá zoom', (tester) async {
      final controller = await pumpMap(tester);
      final before = controller.camera;

      final g1 = await tester.startGesture(const Offset(180, 200));
      final g2 = await tester.startGesture(const Offset(220, 200));
      for (var i = 0; i < 8; i++) {
        await g1.moveBy(const Offset(-5, 0));
        await g2.moveBy(const Offset(5, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g1.up();
      await g2.up();
      await tester.pump(const Duration(milliseconds: 50));

      expect(controller.camera.rotation, 0);
      expect(controller.camera.zoom, greaterThan(before.zoom));
    });
  });

  group('Map Split Layout Tests', () {
    // Paisagem: o card das paradas divide a tela com o mapa (estilo Circuit).
    test('Painel lateral em paisagem (visão geral e navegação)', () {
      expect(
        MapSplitLayout.showsSidePanel(isLandscape: true, isNavigating: false),
        isTrue,
      );
      expect(
        MapSplitLayout.showsSidePanel(isLandscape: true, isNavigating: true),
        isTrue,
      );
      expect(
        MapSplitLayout.showsSidePanel(isLandscape: false, isNavigating: false),
        isFalse,
      );
      expect(
        MapSplitLayout.showsSidePanel(isLandscape: false, isNavigating: true),
        isFalse,
      );
    });

    test('Largura do painel respeita piso e teto', () {
      // Celular em paisagem (~914 x 412 lógicos): 38% da largura.
      expect(MapSplitLayout.panelWidth(914), closeTo(347.32, 0.01));
      // Tela estreita: o painel não vira tira ilegível.
      expect(MapSplitLayout.panelWidth(360), MapSplitLayout.minPanelWidth);
      // Tablet: o mapa continua sendo a maior parte da tela.
      expect(MapSplitLayout.panelWidth(1920), MapSplitLayout.maxPanelWidth);

      // Em qualquer largura real de paisagem o mapa fica com mais da metade.
      for (final w in [914.0, 1280.0, 1920.0]) {
        expect(w - MapSplitLayout.panelWidth(w), greaterThan(w / 2),
            reason: 'mapa tem que sobrar mais da metade em $w');
      }
    });
  });

  group('Map Tiles Tests', () {
    // Trava a fonte dos tiles: os três endpoints que o app raspava antes e que
    // causavam bloqueio silencioso (mapa branco) não podem voltar — o mt{s}
    // do Google é fora do ToS, o tile público do OSM proíbe uso pesado e o
    // ArcGIS é best-effort.
    const blockedHosts = [
      'google.com/vt',
      'mt0.google.com',
      'mt1.google.com',
      'tile.openstreetmap.org',
      'arcgisonline.com',
    ];

    test('Nenhuma camada usa host bloqueado ou fora do ToS', () {
      for (final url in [
        MapTiles.roads,
        MapTiles.roadsDark,
        MapTiles.satellite,
      ]) {
        for (final host in blockedHosts) {
          expect(url.contains(host), isFalse, reason: '$url contém $host');
        }
        expect(url.startsWith('https://api.mapbox.com/styles/v1/'), isTrue);
      }
    });

    test('Cada camada aponta para o estilo certo e leva o token', () {
      expect(MapTiles.roads, contains('/streets-v12/'));
      expect(MapTiles.roadsDark, contains('/dark-v11/'));
      expect(MapTiles.satellite, contains('/satellite-streets-v12/'));

      for (final url in [
        MapTiles.roads,
        MapTiles.roadsDark,
        MapTiles.satellite,
      ]) {
        expect(url, contains('{z}'));
        expect(url, contains('{x}'));
        expect(url, contains('{y}'));
        // {r} é o que vira @2x quando a camada liga retinaMode.
        expect(url, contains('{r}'));
        expect(url, contains('access_token=pk.'));
      }
    });

    test('Atribuição exigida por licença está preenchida', () {
      expect(MapTiles.attribution, contains('Mapbox'));
      expect(MapTiles.attribution, contains('OpenStreetMap'));
      expect(MapTiles.attributionSatellite, contains('Maxar'));
    });

    test('Com key CARTO, vias usam basemaps (sem Mapbox nas ruas)', () {
      MapTiles.setCartoKey('cb1_test_key');
      try {
        expect(MapTiles.roads, contains('basemaps.cartocdn.com'));
        expect(MapTiles.roads, contains('/voyager/'));
        expect(MapTiles.roads, contains('key=cb1_test_key'));
        expect(MapTiles.roadsDark, contains('/dark_all/'));
        expect(MapTiles.roadsDark, contains('key=cb1_test_key'));
        expect(MapTiles.roads.contains('mapbox'), isFalse);
        // Satélite continua Mapbox (melhor imagem).
        expect(MapTiles.satellite, contains('mapbox'));
        expect(MapTiles.attribution, contains('CARTO'));
      } finally {
        MapTiles.setCartoKey(null);
      }
      // Sem key: fallback Mapbox (comportamento antigo intacto).
      expect(MapTiles.roads, contains('/streets-v12/'));
    });

    test('Token Mapbox rotaciona via servidor (override + reset)', () {
      MapTiles.setMapboxToken('pk.test_override');
      try {
        expect(MapTiles.satellite, contains('pk.test_override'));
      } finally {
        MapTiles.setMapboxToken(null);
      }
      expect(MapTiles.satellite, contains('access_token=pk.'));
    });
  });

  group('LIFO Engine & Immutable Versioning Tests', () {
    test(
      'LIFO Spatial Slot mapping conforms strictly to delivery sequence',
      () {
        final slot1 = SpatialSlot.slotForDeliverySequence(1, 6);
        final slot2 = SpatialSlot.slotForDeliverySequence(2, 6);
        final slot3 = SpatialSlot.slotForDeliverySequence(3, 6);
        final slot4 = SpatialSlot.slotForDeliverySequence(4, 6);
        final slot5 = SpatialSlot.slotForDeliverySequence(5, 6);
        final slot6 = SpatialSlot.slotForDeliverySequence(6, 6);

        // Stop 1 must be unloaded first -> Door access
        expect(slot1.type, SpatialSlotType.portaTraseira);
        expect(slot1.unloadingOrder, 1);

        // Stop 2 -> Side door
        expect(slot2.type, SpatialSlotType.portaLateral);
        expect(slot2.unloadingOrder, 2);

        // Stop 3 -> Mid right
        expect(slot3.type, SpatialSlotType.meioDireito);

        // Stop 4 -> Mid left
        expect(slot4.type, SpatialSlotType.meioEsquerdo);

        // Stop 5 -> Deep right
        expect(slot5.type, SpatialSlotType.fundoDireito);

        // Stop 6 -> Deep left (Loaded first, unloaded last)
        expect(slot6.type, SpatialSlotType.fundoEsquerdo);
        expect(slot6.loadingOrder, 1);
      },
    );

    test('Compartimentos extras existem e resolvem por tipo e label', () {
      expect(SpatialSlot.allSlots.length, 12);

      // As 6 zonas base seguem nas mesmas posições (nada mudou pra elas).
      expect(SpatialSlot.allSlots.first.type, SpatialSlotType.fundoEsquerdo);
      expect(SpatialSlot.allSlots[5].type, SpatialSlotType.portaTraseira);

      expect(
        SpatialSlot.fromType(SpatialSlotType.compartimento7).label,
        'Compartimento 7',
      );
      expect(
        SpatialSlot.fromString('Compartimento 12').type,
        SpatialSlotType.compartimento12,
      );

      // O LIFO continua mapeando apenas as zonas base.
      expect(
        SpatialSlot.slotForDeliverySequence(1, 10).type,
        SpatialSlotType.portaTraseira,
      );
      expect(
        SpatialSlot.slotForDeliverySequence(9, 10).type,
        SpatialSlotType.fundoEsquerdo,
      );
    });

    test('Route optimizer reassigns LIFO slots and sequences', () {
      final stops = [
        DeliveryStop(
          id: 'stop-1',
          manifestVersionId: 'v-0',
          sequenceIndex: 1,
          recipientName: 'Destino A',
          address: 'Rua A, 100',
          latitude: -23.5505,
          longitude: -46.6333,
          spatialSlot: SpatialSlot.fundoEsquerdo,
          packages: [
            const PackageItem(
              id: 'p-1',
              manifestVersionId: 'v-0',
              stopId: 'stop-1',
              barcode: 'LF-100',
              description: 'Carga 1',
              weightKg: 10.0,
              spatialSlot: SpatialSlot.fundoEsquerdo,
            ),
          ],
        ),
        DeliveryStop(
          id: 'stop-2',
          manifestVersionId: 'v-0',
          sequenceIndex: 2,
          recipientName: 'Destino B',
          address: 'Rua B, 200',
          latitude: -23.5600,
          longitude: -46.6400,
          spatialSlot: SpatialSlot.fundoEsquerdo,
          packages: [
            const PackageItem(
              id: 'p-2',
              manifestVersionId: 'v-0',
              stopId: 'stop-2',
              barcode: 'LF-200',
              description: 'Carga 2',
              weightKg: 5.0,
              spatialSlot: SpatialSlot.fundoEsquerdo,
            ),
          ],
        ),
      ];

      final optimized = LifoCalculator.optimizeRouteStops(stops);
      expect(optimized.length, 2);
      expect(optimized.first.sequenceIndex, 1);
      expect(optimized.first.spatialSlot.type, SpatialSlotType.portaTraseira);
      expect(optimized.last.sequenceIndex, 2);
      expect(optimized.last.spatialSlot.type, SpatialSlotType.portaLateral);
    });

    test('PackageItem preserva slotUserAssigned no toMap/fromMap', () {
      const pkg = PackageItem(
        id: 'p-1',
        manifestVersionId: 'v-0',
        stopId: 'stop-1',
        barcode: 'LF-100',
        description: 'Carga',
        weightKg: 1.0,
        spatialSlot: SpatialSlot.portaTraseira,
      );

      // Por padrão é local automático (não colocado pelo usuário).
      expect(pkg.slotUserAssigned, isFalse);
      expect(PackageItem.fromMap(pkg.toMap()).slotUserAssigned, isFalse);

      final assigned = pkg.copyWith(
        slotUserAssigned: true,
        spatialSlot: SpatialSlot.meioEsquerdo,
      );
      final restored = PackageItem.fromMap(assigned.toMap());
      expect(restored.slotUserAssigned, isTrue);
      expect(restored.spatialSlot.type, SpatialSlotType.meioEsquerdo);
    });

    test('PackageItem sem peso grava 0 na linha e volta como null', () {
      const pkg = PackageItem(
        id: 'p-nw',
        manifestVersionId: 'v-0',
        stopId: 'stop-1',
        barcode: 'LF-500',
        description: 'Sem peso',
        spatialSlot: SpatialSlot.portaTraseira,
      );

      expect(pkg.weightKg, isNull);
      // weight_kg é NOT NULL: 0 = desconhecido, e volta como null na leitura.
      expect(pkg.toMap()['weight_kg'], 0);
      expect(PackageItem.fromMap(pkg.toMap()).weightKg, isNull);

      final weighed = pkg.copyWith(weightKg: 3.5);
      expect(PackageItem.fromMap(weighed.toMap()).weightKg, 3.5);
    });

    test('LIFO não sobrescreve o local colocado pelo usuário no baú', () {
      final stops = [
        DeliveryStop(
          id: 'stop-1',
          manifestVersionId: 'v-0',
          sequenceIndex: 1,
          recipientName: 'Destino A',
          address: 'Rua A, 100',
          latitude: -23.5505,
          longitude: -46.6333,
          spatialSlot: SpatialSlot.meioEsquerdo,
          packages: [
            const PackageItem(
              id: 'p-1',
              manifestVersionId: 'v-0',
              stopId: 'stop-1',
              barcode: 'LF-100',
              description: 'Carga',
              weightKg: 1.0,
              spatialSlot: SpatialSlot.meioEsquerdo,
              slotUserAssigned: true,
            ),
          ],
        ),
      ];

      final optimized = LifoCalculator.optimizeRouteStops(stops);
      // A parada 1 receberia Porta Traseira, mas o volume foi colocado à mão
      // no Meio Esquerdo — o LIFO não pode sobrescrever essa escolha.
      expect(
        optimized.first.packages.first.spatialSlot.type,
        SpatialSlotType.meioEsquerdo,
      );
      expect(optimized.first.packages.first.slotUserAssigned, isTrue);
    });

    test('Immutable Manifest Version 0 is preserved as original', () {
      final v0 = ManifestVersion(
        id: 'v0-uuid',
        versionIndex: 0,
        label: 'Manifesto Original',
        rawData: '{"stops": []}',
        createdAt: DateTime.now(),
        isCurrent: true,
        totalStops: 0,
        totalPackages: 0,
      );

      expect(v0.isOriginal, isTrue);
      expect(v0.versionIndex, 0);
    });

    test('Arrival offsets accumulate OSRM legs with and without start', () {
      // Com start (GPS/depósito): leg j leva até a parada j.
      final withStart = RoutingResult.arrivalOffsets(
        legDurations: [100, 200, 300],
        stopCount: 3,
        hasStart: true,
      );
      expect(withStart, [100, 300, 600]);

      // Sem start: parada 1 é a origem (offset 0).
      final noStart = RoutingResult.arrivalOffsets(
        legDurations: [200, 300],
        stopCount: 3,
        hasStart: false,
      );
      expect(noStart, [0, 200, 500]);

      // Offline (sem legs): offsets zerados, sem crash.
      final offline = RoutingResult.arrivalOffsets(
        legDurations: [],
        stopCount: 2,
        hasStart: false,
      );
      expect(offline, [0, 0]);
    });
  });

  group('Manifest Import Tests', () {
    test(
      'Amazon TXT tabulado: detecta, agrupa por pedido e monta endereço',
      () {
        final rows = [
          [
            'order-id',
            'recipient-name',
            'ship-address-1',
            'ship-city',
            'ship-state',
            'ship-postal-code',
            'product-name',
            'quantity-purchased',
            'sku',
          ],
          [
            '111-222',
            'Maria Silva',
            'Rua das Flores 123',
            'São Paulo',
            'SP',
            '01310-100',
            'Camiseta',
            '1',
            'CAM-AZ',
          ],
          [
            '111-222',
            'Maria Silva',
            'Rua das Flores 123',
            'São Paulo',
            'SP',
            '01310-100',
            'Boné',
            '2',
            'BONE-AZ',
          ],
          [
            '333-444',
            'João Souza',
            'Av Brasil 500',
            'Campinas',
            'SP',
            '13000-000',
            'Tênis',
            '1',
            'TEN-AZ',
          ],
        ];

        final parsed = ManifestImportService.parseRows(rows);
        expect(parsed.detectedFormat, MarketplaceFormat.amazon);
        expect(parsed.stops.length, 2);
        expect(parsed.stops.first.orderRef, '111-222');
        expect(parsed.stops.first.items.length, 2);
        expect(parsed.stops.first.totalUnits, 3);
        expect(parsed.stops.first.addressQuery, contains('São Paulo - SP'));
      },
    );

    test('Shopee XLSX: detecta e pula cancelados', () {
      final rows = [
        [
          'Order ID',
          'Username (Buyer)',
          'Product Name',
          'SKU Reference No.',
          'Quantity',
          'Order Status',
          'Shipping Address',
          'City',
        ],
        [
          'SP-1',
          'buyer_ana',
          'Fone Bluetooth',
          'FONE-01',
          '1',
          'To Ship',
          'Rua A, 10',
          'Santos',
        ],
        [
          'SP-2',
          'buyer_bia',
          'Capa Celular',
          'CAPA-02',
          '3',
          'Cancelled',
          'Rua B, 20',
          'Guarujá',
        ],
      ];

      final parsed = ManifestImportService.parseRows(rows);
      expect(parsed.detectedFormat, MarketplaceFormat.shopee);
      expect(parsed.stops.length, 1);
      expect(parsed.skippedCancelled, 1);
      expect(parsed.stops.first.items.first.quantity, 1);
    });

    test('CSV genérico PT-BR: ignora sem-endereço e expande volumes', () {
      final rows = [
        [
          'Nº Pedido',
          'Destinatário',
          'Rua',
          'Número',
          'Cidade',
          'UF',
          'CEP',
          'Produto',
          'Qtd',
        ],
        [
          'ML-10',
          'Carlos Lima',
          'Rua XV',
          '77',
          'Curitiba',
          'PR',
          '80020-310',
          'Monitor',
          '2',
        ],
        ['ML-11', 'Sem Endereco', '', '', '', '', '', 'Teclado', '1'],
      ];

      final parsed = ManifestImportService.parseRows(rows);
      expect(parsed.detectedFormat, MarketplaceFormat.generic);
      expect(parsed.stops.length, 1);
      expect(parsed.rowsWithoutAddress, 1);

      final resolved = ManifestImportService.resolve(
        parsed.stops.first,
        -25.4,
        -49.2,
      );
      expect(resolved.items.length, 2);
      expect(resolved.items[0].barcode, 'ML-10-1-1');
      expect(resolved.items[1].barcode, 'ML-10-1-2');
    });

    test('Sem coluna de peso, o volume fica sem peso (não vira 1 kg)', () {
      final rows = [
        [
          'Nº Pedido',
          'Destinatário',
          'Rua',
          'Número',
          'Cidade',
          'UF',
          'CEP',
          'Produto',
          'Qtd',
        ],
        [
          'ML-20',
          'Ana Souza',
          'Rua A',
          '10',
          'Curitiba',
          'PR',
          '80000-000',
          'Caixa',
          '2',
        ],
      ];

      final parsed = ManifestImportService.parseRows(rows);
      expect(parsed.stops.first.items.first.weightKg, isNull);

      final resolved = ManifestImportService.resolve(
        parsed.stops.first,
        -25.4,
        -49.2,
      );
      expect(resolved.items.every((i) => i.weightKg == null), isTrue);
    });

    test('Com coluna de peso, o valor real do arquivo é lido', () {
      final rows = [
        [
          'Nº Pedido',
          'Destinatário',
          'Rua',
          'Número',
          'Cidade',
          'UF',
          'CEP',
          'Produto',
          'Qtd',
          'Peso',
        ],
        [
          'ML-21',
          'Ana Souza',
          'Rua A',
          '10',
          'Curitiba',
          'PR',
          '80000-000',
          'Caixa',
          '1',
          '12,5',
        ],
      ];

      final parsed = ManifestImportService.parseRows(rows);
      expect(parsed.stops.first.items.first.weightKg, 12.5);
    });

    test('readRows lê CSV com ponto-e-vírgula e latin1', () async {
      final service = ManifestImportService();
      final bytes = latin1.encode('Pedido;Destinatario\nA1;José\n');
      final rows = await service.readRows('vendas.csv', bytes);
      expect(rows.length, 2);
      expect(rows[0], ['Pedido', 'Destinatario']);
      expect(rows[1][1], 'José');
    });

    test(
      'Manifesto transportadora: usa coords do arquivo e agrupa por Stop',
      () {
        final rows = [
          [
            'AT ID',
            'Sequence',
            'Stop',
            'SPX TN',
            'Destination Address',
            'Bairro',
            'City',
            'Zipcode/Postal code',
            'Latitude',
            'Longitude',
          ],
          [
            'AT1',
            '2',
            '2',
            'BR001',
            'Rua Lírio da Paz, 134',
            'Saco Grande',
            'Florianópolis',
            '88032-175',
            '-27,54809',
            '-48,4953384',
          ],
          [
            'AT1',
            '3',
            '2',
            'BR002',
            'Rua Lírio da Paz, 134',
            'Saco Grande',
            'Florianópolis',
            '88032-175',
            '-27,54809',
            '-48,4953384',
          ],
          [
            'AT1',
            '4',
            '3',
            'BR003',
            'Rodovia Virgílio Várzea, 1510',
            'Saco Grande',
            'Florianópolis',
            '88032-001',
            '-27.5467339',
            '-48.4968758',
          ],
          [
            'AT1',
            '-',
            '-',
            'BR004',
            'Rua da Apicultura, 244',
            'Saco Grande',
            'Florianópolis',
            '88032-020',
            '-27,53521',
            '-48,503226',
          ],
        ];

        final parsed = ManifestImportService.parseRows(rows);
        expect(parsed.stops.length, 3);

        final stop2 = parsed.stops.firstWhere((s) => s.orderRef == 'PED-1');
        expect(stop2.items.length, 2);
        expect(stop2.items.first.barcodeBase, 'BR001');
        expect(stop2.latitude, closeTo(-27.54809, 0.00001));
        expect(stop2.longitude, closeTo(-48.4953384, 0.00001));
        expect(stop2.hasCoords, isTrue);
        expect(stop2.recipient, contains('Lírio da Paz'));

        final single = parsed.stops.firstWhere((s) => s.orderRef == 'PED-4');
        expect(single.latitude, closeTo(-27.53521, 0.00001));
        expect(single.items.single.barcodeBase, 'BR004');
      },
    );

    test('Coords trocadas são desinvertidas; inválidas viram null', () {
      final rows = [
        [
          'Stop',
          'SPX TN',
          'Destination Address',
          'City',
          'Latitude',
          'Longitude',
        ],
        ['1', 'BR010', 'Rua A, 1', 'Florianópolis', '120,5', '-27,53'],
        ['2', 'BR011', 'Rua B, 2', 'Florianópolis', '-', '-'],
      ];
      final parsed = ManifestImportService.parseRows(rows);
      final swapped = parsed.stops[0];
      expect(swapped.latitude, closeTo(-27.53, 0.00001));
      expect(swapped.longitude, closeTo(120.5, 0.00001));
      expect(parsed.stops[1].hasCoords, isFalse);
    });
  });

  group('TSP Engine Tests', () {
    DeliveryStop stop(String id, double lat, double lng) {
      return DeliveryStop(
        id: id,
        manifestVersionId: 'v',
        sequenceIndex: 0,
        recipientName: id,
        address: id,
        latitude: lat,
        longitude: lng,
        spatialSlot: SpatialSlot.fundoEsquerdo,
      );
    }

    test('2-opt desfaz cruzamento e encurta o trajeto', () {
      final a = stop('A', 0, 0);
      final b = stop('B', 0, 1);
      final c = stop('C', 1, 1);
      final d = stop('D', 1, 0);
      final crossed = [a, c, b, d];

      final before = LifoCalculator.pathLength(crossed);
      final fixed = LifoCalculator.twoOpt(crossed);
      final after = LifoCalculator.pathLength(fixed);

      expect(after, lessThan(before));
      // Turno aberto ótimo = 3 lados (~333 km no equador).
      expect(after, closeTo(3 * 111195, 3 * 111195 * 0.05));
    });

    test('2-opt com start conta a aresta do GPS e melhora', () {
      final far = stop('far', 0, 5);
      final n1 = stop('n1', 0, 1);
      final n2 = stop('n2', 0, 2);
      final ordered = [far, n2, n1];

      final before = LifoCalculator.pathLength(
        ordered,
        startLat: 0,
        startLng: 0,
      );
      final fixed = LifoCalculator.twoOpt(ordered, startLat: 0, startLng: 0);
      final after = LifoCalculator.pathLength(fixed, startLat: 0, startLng: 0);

      expect(after, lessThan(before));
      // Ótimo partindo do GPS (0,0): 0->1->2->5 = 5 lados.
      expect(after, closeTo(5 * 111195, 5 * 111195 * 0.05));
      expect(fixed.first.id, 'n1');
    });

    test('pathLength sem start parte da primeira parada (trecho zero)', () {
      final a = stop('A', 0, 0);
      expect(LifoCalculator.pathLength([a]), 0);
      expect(
        LifoCalculator.pathLength([a], startLat: 0, startLng: 1),
        closeTo(111195, 111195 * 0.01),
      );
    });

    test('2-opt fixFirst trava a 1 e otimiza só a cauda', () {
      final n1 = stop('n1', 0, 1);
      final far = stop('far', 0, 5);
      final n2 = stop('n2', 0, 2);
      final fixed = LifoCalculator.twoOpt(
        [n1, far, n2],
        startLat: 0,
        startLng: 0,
        fixFirst: true,
      );
      // 1 travada como a mais perto do GPS; cauda em ordem crescente.
      expect(fixed.map((s) => s.id).toList(), ['n1', 'n2', 'far']);
      expect(
        LifoCalculator.pathLength(fixed, startLat: 0, startLng: 0),
        closeTo(5 * 111195, 5 * 111195 * 0.05),
      );
    });

    test('optimizeRouteStops: 1 é a mais perto do GPS com slots LIFO', () {
      final far = stop('far', 0, 5);
      final n1 = stop('n1', 0, 1);
      final n2 = stop('n2', 0, 2);
      final result = LifoCalculator.optimizeRouteStops(
        [far, n2, n1],
        startLat: 0,
        startLng: 0,
      );
      expect(result.map((s) => s.sequenceIndex).toList(), [1, 2, 3]);
      expect(result.first.id, 'n1');
      expect(result.first.spatialSlot.type, SpatialSlotType.portaTraseira);
    });

    test('cadeia NN por matriz: 1 = menor tempo de rua do GPS', () {
      // Índice 0 = GPS; valores = segundos de rua (não linha reta).
      final matrix = [
        [0.0, 600.0, 120.0, 300.0],
        [600.0, 0.0, 500.0, 100.0],
        [120.0, 500.0, 0.0, 400.0],
        [300.0, 100.0, 400.0, 0.0],
      ];
      final chain = LifoCalculator.nearestNeighborWithMatrix(matrix);
      // 0->2 (120s), 2->3 (400s), 3->1 — nunca pela reta.
      expect(chain, [0, 2, 3, 1]);
    });

    test('optimizeWithMatrix mapeia paradas com matriz de rua', () {
      final s1 = stop('s1', 0, 1);
      final s2 = stop('s2', 0, 2);
      final s3 = stop('s3', 0, 3);
      final matrix = [
        [0.0, 600.0, 120.0, 300.0],
        [600.0, 0.0, 500.0, 100.0],
        [120.0, 500.0, 0.0, 400.0],
        [300.0, 100.0, 400.0, 0.0],
      ];
      final ordered = LifoCalculator.optimizeWithMatrix([s1, s2, s3], matrix);
      expect(ordered.map((s) => s.id).toList(), ['s2', 's3', 's1']);
    });

    test(
      'optimizeWithMatrix permite trocar a primeira parada para reduzir o conjunto',
      () {
        final s1 = stop('s1', 0, 1);
        final s2 = stop('s2', 0, 2);
        final s3 = stop('s3', 0, 3);

        // NN comecaria em s1: 0->1->2->3 = 52s.
        // O 2-opt global melhora para 0->3->2->1 = 4s.
        final matrix = [
          [0.0, 1.0, 9.0, 2.0],
          [1.0, 0.0, 50.0, 100.0],
          [9.0, 1.0, 0.0, 1.0],
          [2.0, 100.0, 1.0, 0.0],
        ];

        final ordered = LifoCalculator.optimizeWithMatrix([s1, s2, s3], matrix);
        expect(ordered.map((s) => s.id).toList(), ['s3', 's2', 's1']);
      },
    );
  });

  group('Map Framing Tests', () {
    test('frameForPoints centra e nunca estoura o zoom', () {
      // 98 paradas espalhadas por Florianópolis (caso real do import).
      final points = [
        const LatLng(-27.5950, -48.5480),
        const LatLng(-27.6200, -48.5200),
        const LatLng(-27.5800, -48.5800),
      ];
      final frame = LogisticsMapCanvas.frameForPoints(
        points: points,
        viewportWidth: 1220,
        viewportHeight: 1400,
      );
      expect(frame.center.latitude, closeTo(-27.6, 0.05));
      expect(frame.center.longitude, closeTo(-48.55, 0.05));
      expect(frame.zoom, greaterThanOrEqualTo(3.0));
      expect(frame.zoom, lessThanOrEqualTo(16.0));

      // Ponto único: zoom máximo na rua, sem exceção.
      final single = LogisticsMapCanvas.frameForPoints(
        points: const [LatLng(-27.6, -48.55)],
        viewportWidth: 1220,
        viewportHeight: 1400,
      );
      expect(single.center, const LatLng(-27.6, -48.55));
      expect(single.zoom, 16.0);
    });
  });

  group('App Headers Tests', () {
    // Trava mobile da CARTO cobra pacote + SHA-1 do cert. O formato tem que
    // ser idêntico ao do keytool ("AA:BB:...", maiúsculo), senão 403.
    test('SHA-1 formata igual ao keytool', () {
      expect(
        AppHeadersService.formatCertSha1([0x67, 0xBB, 0x09, 0x00, 0xFF]),
        '67:BB:09:00:FF',
      );
      expect(AppHeadersService.formatCertSha1([]), isEmpty);
    });

    test('Headers incluem pacote, cert e User-Agent', () async {
      final h = await AppHeadersService.instance.tileHeaders();
      expect(h['User-Agent'], contains('LifoApp'));
      // Em teste (sem canal nativo) ao menos o UA existe e não lança.
      expect(AppHeadersService.instance.tileHeadersSync['User-Agent'],
          contains('LifoApp'));
      AppHeadersService.instance.debugReset();
    });
  });

  group('HUD Street Tests', () {
    // Nome da rua atual sai dos steps da perna (sem rede, sem geocode).
    RouteStep step(String street) => RouteStep(
          maneuver: ManeuverType.straight,
          distanceMeters: 100,
          streetName: street,
        );

    test('Rua do último step com nome até o ponto do GPS', () {
      final steps = [step('Rua A'), step('Rua B'), step('Rua C')];
      expect(
        LifoCalculator.streetAtProgress(steps, [0, 50, 120], 60),
        'Rua B',
      );
      expect(
        LifoCalculator.streetAtProgress(steps, [0, 50, 120], 200),
        'Rua C',
      );
    });

    test('Step sem nome pula para o anterior com nome', () {
      final steps = [step('Rua A'), step(''), step('Rua C')];
      expect(
        LifoCalculator.streetAtProgress(steps, [0, 50, 120], 60),
        'Rua A',
      );
    });

    test('Sem steps ou índices fora retorna null', () {
      expect(LifoCalculator.streetAtProgress(const [], const [], 0), isNull);
      final steps = [step('Rua A')];
      expect(LifoCalculator.streetAtProgress(steps, const [], 0), isNull);
      expect(LifoCalculator.streetAtProgress(steps, [-1], 99), isNull);
    });
  });

  group('Route Simplify Tests', () {
    // Douglas-Peucker display-only: corta pontos sem mexer no desenho.
    // A geometria cheia segue no estado/banco/HUD — aqui só o render.
    List<LatLng> straightLine(int n) => [
          for (var i = 0; i < n; i++)
            LatLng(-27.6 + i * 0.00001, -48.5 + i * 0.00001),
        ];

    test('Reta com 500 pontos colapsa mantendo extremos', () {
      final pts = straightLine(500);
      final out = RouteSimplify.douglasPeucker(pts);
      expect(out.first, pts.first);
      expect(out.last, pts.last);
      expect(out.length, lessThan(10));
    });

    test('Zigue-zague preserva as curvas', () {
      final pts = <LatLng>[
        const LatLng(0, 0),
        const LatLng(0.001, 0.001),
        const LatLng(0.002, 0), // pico fora da tolerância
        const LatLng(0.003, 0.001),
        const LatLng(0.004, 0),
      ];
      final out = RouteSimplify.douglasPeucker(
        pts,
        toleranceDeg: 0.00001,
      );
      // Pico de 0.001° (~111m) sobrevive à tolerância de ~1m.
      expect(out.length, greaterThan(2));
      expect(out.first, pts.first);
      expect(out.last, pts.last);
    });

    test('Lista curta volta intacta', () {
      const pts = [LatLng(-27.6, -48.5), LatLng(-27.61, -48.51)];
      expect(RouteSimplify.douglasPeucker(pts), hasLength(2));
      expect(RouteSimplify.douglasPeucker(const []), isEmpty);
    });
  });

  group('Card arrastável: AnimatedSwitcher da troca de parada', () {
    // Config idêntica à do card de navegação (home_dashboard_screen). O
    // overshoot mora DENTRO do transitionBuilder — nunca no switchInCurve,
    // porque o switcher entrega ao builder a animação JÁ curvada e o t
    // estoura 1.0 (assert → ErrorWidget vermelho durante o swipe).
    Future<void> pumpSwitcher(WidgetTester tester, String stopId) {
      return tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 400),
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, animation) {
                  return FadeTransition(
                    opacity: animation,
                    child: ScaleTransition(
                      scale: Tween<double>(begin: 0.95, end: 1.0).animate(
                        CurvedAnimation(
                          parent: animation,
                          curve: Curves.easeOutBack,
                        ),
                      ),
                      child: child,
                    ),
                  );
                },
                child: SizedBox(
                  key: ValueKey(stopId),
                  width: 200,
                  height: 100,
                ),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('Troca de parada anima com overshoot sem tela vermelha',
        (tester) async {
      await pumpSwitcher(tester, 'parada_1');
      await tester.pumpAndSettle();

      // Swipe para a próxima parada: o card troca de chave e anima.
      await pumpSwitcher(tester, 'parada_2');

      double maxScale = 0.0;
      for (var i = 0; i < 25; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        for (final s
            in tester.widgetList<ScaleTransition>(find.byType(ScaleTransition))) {
          if (s.scale.value > maxScale) maxScale = s.scale.value;
        }
      }

      expect(
        tester.takeException(),
        isNull,
        reason: 'curva com overshoot no switchInCurve estoura t em [0,1]',
      );
      expect(
        maxScale,
        greaterThan(1.0),
        reason: 'o card tem que continuar com o pulo do overshoot ao trocar',
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    test('Nenhuma tela usa curva com overshoot em switchInCurve/switchOutCurve',
        () {
      // Guarda de fonte: o assert só acontece em debug (tela vermelha), mas o
      // efeito em release (alpha > 255, escala torta) também é errado. O
      // overshoot tem que ficar no transitionBuilder, onde t já é <= 1.
      final overshootSwitchCurve = RegExp(
        r'switch(In|Out)Curve:\s*Curves\.(easeOutBack|easeInBack|'
        r'easeOutElastic|easeInElastic|easeOutBounce|easeInBounce)',
      );
      final offenders = <String>[];
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        if (overshootSwitchCurve.hasMatch(entity.readAsStringSync())) {
          offenders.add(entity.path);
        }
      }
      expect(offenders, isEmpty, reason: 'use o overshoot no transitionBuilder');
    });
  });

  group('Atualização do app (nunca baixa a versão já instalada)', () {
    test('Compara versões campo a campo (com lacunas)', () {
      expect(AppUpdateService.compareVersions('1.0.1', '1.0.0'), 1);
      expect(AppUpdateService.compareVersions('1.0.0', '1.0.1'), -1);
      expect(AppUpdateService.compareVersions('1.0.0', '1.0.0'), 0);
      expect(AppUpdateService.compareVersions('1.0', '1.0.0'), 0);
      expect(AppUpdateService.compareVersions('1.0.0', '1.0'), 0);
      expect(AppUpdateService.compareVersions('1.2', '1.10'), -1);
      expect(AppUpdateService.compareVersions('2.0.0', '1.99.99'), 1);
      // Campo não numérico conta como 0 — nunca lança.
      expect(AppUpdateService.compareVersions('1.beta', '1.0'), 0);
      expect(AppUpdateService.compareVersions('', '0.0.0'), 0);
    });

    // Regra do campo: só não baixar o que JÁ está instalado. Nome ou build
    // diferentes = oferece (inclusive rebuild e rollback).
    bool differs(
      String rv,
      int rb,
      String iv,
      int ib,
    ) =>
        AppUpdateService.differsFromInstalled(
          remoteVersion: rv,
          remoteBuild: rb,
          installedVersion: iv,
          installedBuild: ib,
        );

    test('Rebuild do mesmo release (nome igual, build novo) vira oferta', () {
      expect(differs('1.0.0', 2, '1.0.0', 1), isTrue);
    });

    test('Nome novo vira oferta mesmo com build igual', () {
      expect(differs('1.0.1', 1, '1.0.0', 1), isTrue);
    });

    test('Rollback publicado também é oferecido (quem decide é o Android)', () {
      expect(differs('1.0.0', 1, '1.0.1', 2), isTrue);
    });

    test('Mesma versão E mesmo build não vira oferta', () {
      expect(differs('1.0.0', 1, '1.0.0', 1), isFalse);
      // "1.0" x "1.0.0" é o mesmo número: oferecer download daria
      // "app já instalado" no Android.
      expect(differs('1.0', 1, '1.0.0', 1), isFalse);
      expect(differs('1.0.0', 0, '1.0', 0), isFalse);
    });

    test('Só a publicada mais antiga dispara o aviso de versão anterior', () {
      bool older(String rv, int rb, String iv, int ib) =>
          AppUpdateService.isOlder(
            remoteVersion: rv,
            remoteBuild: rb,
            installedVersion: iv,
            installedBuild: ib,
          );

      expect(older('1.0.0', 1, '1.0.1', 2), isTrue);
      expect(older('1.0.0', 1, '1.0.0', 2), isTrue);
      expect(older('1.0.1', 2, '1.0.0', 1), isFalse);
      expect(older('1.0.0', 1, '1.0.0', 1), isFalse);
    });

    test('app_config sem as chaves de release = nada publicado', () {
      // Estado real do servidor antes do 1º release: só carto_key/mapbox_token.
      // A consulta volta vazia — isso é ausência de publicação, não internet.
      final rows = <Map<String, String>>[
        {'key': 'carto_key', 'value': 'x'},
        {'key': 'mapbox_token', 'value': 'y'},
      ];
      final map = {for (final r in rows) r['key']: r['value']};
      expect(
        AppRelease.fromJson({
          'version': map['latest_version'] ?? '',
          'build': int.tryParse(map['latest_build'] ?? '') ?? 0,
          'apk_url': map['apk_url'] ?? '',
          'notes': map['release_notes'] ?? '',
        }),
        isNull,
      );
    });

    test('Registro incompleto não vira oferta de update', () {
      expect(AppRelease.fromJson(const {}), isNull);
      expect(
        AppRelease.fromJson(const {'version': '1.0.1', 'apk_url': '  '}),
        isNull,
        reason: 'sem URL não há o que baixar',
      );
      expect(
        AppRelease.fromJson(const {'version': '', 'apk_url': 'https://x/l.apk'}),
        isNull,
      );
      final ok = AppRelease.fromJson(const {
        'version': '1.0.1',
        'build': '2',
        'apk_url': 'https://lifo.com.br/lifo.apk',
        'notes': ' Correções ',
      });
      expect(ok, isNotNull);
      expect(ok!.version, '1.0.1');
      expect(ok.build, 2);
      expect(ok.apkUrl, 'https://lifo.com.br/lifo.apk');
      expect(ok.notes, 'Correções');
    });

    test('Todo campo lido pelo app é publicado pelo SQL de release', () {
      // Guarda de contrato: o SQL é quem grava o release, o app é quem lê.
      // Renomear uma chave de um lado só deixa a bolhinha morta em silêncio.
      final sql = File('supabase/release_apk.sql').readAsStringSync();
      for (final key in AppUpdateService.configKeys) {
        expect(
          sql.contains("'$key'"),
          isTrue,
          reason: 'release_apk.sql precisa publicar a chave $key',
        );
      }
    });
  });
}
