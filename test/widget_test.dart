import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:lifo/core/services/hybrid_routing_service.dart';
import 'package:lifo/core/services/manifest_import_service.dart';
import 'package:lifo/core/utils/lifo_calculator.dart';
import 'package:lifo/features/navigation_map/presentation/widgets/logistics_map_canvas.dart';
import 'package:lifo/features/route_manifest/domain/models/delivery_stop.dart';
import 'package:lifo/features/route_manifest/domain/models/package_item.dart';
import 'package:lifo/features/route_manifest/domain/models/spatial_slot.dart';
import 'package:lifo/features/route_manifest/domain/models/manifest_version.dart';

void main() {
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
}
