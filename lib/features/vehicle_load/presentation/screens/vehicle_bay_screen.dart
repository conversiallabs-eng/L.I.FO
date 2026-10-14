import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../route_manifest/domain/models/spatial_slot.dart';
import '../../../route_manifest/domain/models/delivery_stop.dart';
import '../../../route_manifest/domain/models/package_item.dart';
import '../../../route_manifest/presentation/manifest_controller.dart';

class VehicleBayScreen extends ConsumerStatefulWidget {
  const VehicleBayScreen({super.key});

  @override
  ConsumerState<VehicleBayScreen> createState() => _VehicleBayScreenState();
}

class _VehicleBayScreenState extends ConsumerState<VehicleBayScreen> {
  int _selectedViewMode = 0; // 0 = Planta Espacial, 1 = Ordem de Carregamento

  @override
  Widget build(BuildContext context) {
    final manifestState = ref.watch(manifestControllerProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final current = manifestState.currentVersion;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Compartimento de Carga LIFO'),
        actions: [
          IconButton(
            tooltip: 'Recalcular LIFO',
            icon: const Icon(Icons.sync_outlined),
            onPressed: () {
              ref.read(manifestControllerProvider.notifier).reoptimizeRoute();
            },
          ),
        ],
      ),
      body: current == null
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // View Mode Selector
                  Container(
                    decoration: BoxDecoration(
                      color: isDark ? AppColors.darkSurface : AppColors.lightSurfaceElevated,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: InkWell(
                            onTap: () => setState(() => _selectedViewMode = 0),
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              decoration: BoxDecoration(
                                color: _selectedViewMode == 0
                                    ? (isDark ? AppColors.primaryBlueLight : AppColors.primaryBlue)
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(9),
                              ),
                              child: Text(
                                'Planta do Veiculo',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 13,
                                  color: _selectedViewMode == 0
                                      ? Colors.white
                                      : (isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary),
                                ),
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          child: InkWell(
                            onTap: () => setState(() => _selectedViewMode = 1),
                            child: Container(
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              decoration: BoxDecoration(
                                color: _selectedViewMode == 1
                                    ? (isDark ? AppColors.primaryBlueLight : AppColors.primaryBlue)
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(9),
                              ),
                              child: Text(
                                'Sequencia de Carga LIFO',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 13,
                                  color: _selectedViewMode == 1
                                      ? Colors.white
                                      : (isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  if (_selectedViewMode == 0)
                    _buildVehicleFloorplan(context, current.stops, isDark)
                  else
                    _buildLoadingSequenceGuide(context, current.stops, isDark),
                ],
              ),
            ),
    );
  }

  Widget _buildVehicleFloorplan(BuildContext context, List<DeliveryStop> stops, bool isDark) {
    // Map stops to slots
    final Map<SpatialSlotType, List<DeliveryStop>> slotStops = {};
    for (final slot in SpatialSlot.allSlots) {
      slotStops[slot.type] = stops.where((s) => s.spatialSlot.type == slot.type).toList();
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: isDark ? AppColors.darkBorder : AppColors.lightBorder, width: 1.5),
      ),
      child: Column(
        children: [
          // Cabin Front Indicator
          Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: isDark ? AppColors.darkSurfaceElevated : AppColors.lightSurfaceElevated,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
            ),
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.directions_car_outlined, size: 18),
                SizedBox(width: 8),
                Text(
                  'FRENTE DO VEICULO / CABINE DO MOTORISTA',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.0,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Row 0: Fundo (Deepest - Loaded first, Unloaded last)
          Row(
            children: [
              Expanded(
                child: _buildSlotBayCard(
                  slot: SpatialSlot.fundoEsquerdo,
                  associatedStops: slotStops[SpatialSlotType.fundoEsquerdo] ?? [],
                  isDark: isDark,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildSlotBayCard(
                  slot: SpatialSlot.fundoDireito,
                  associatedStops: slotStops[SpatialSlotType.fundoDireito] ?? [],
                  isDark: isDark,
                ),
              ),
            ],
          ),

          const SizedBox(height: 8),

          // Row 1: Meio
          Row(
            children: [
              Expanded(
                child: _buildSlotBayCard(
                  slot: SpatialSlot.meioEsquerdo,
                  associatedStops: slotStops[SpatialSlotType.meioEsquerdo] ?? [],
                  isDark: isDark,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildSlotBayCard(
                  slot: SpatialSlot.meioDireito,
                  associatedStops: slotStops[SpatialSlotType.meioDireito] ?? [],
                  isDark: isDark,
                ),
              ),
            ],
          ),

          const SizedBox(height: 8),

          // Row 2: Portas (Immediate Access - Loaded LAST, Unloaded FIRST)
          Row(
            children: [
              Expanded(
                child: _buildSlotBayCard(
                  slot: SpatialSlot.portaTraseira,
                  associatedStops: slotStops[SpatialSlotType.portaTraseira] ?? [],
                  isDark: isDark,
                  isHighPriorityExit: true,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildSlotBayCard(
                  slot: SpatialSlot.portaLateral,
                  associatedStops: slotStops[SpatialSlotType.portaLateral] ?? [],
                  isDark: isDark,
                  isHighPriorityExit: true,
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),

          // Rear Exit Ramp Indicator
          Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.statusSuccess.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.statusSuccess.withValues(alpha: 0.5)),
            ),
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.output, size: 18, color: AppColors.statusSuccess),
                SizedBox(width: 8),
                Text(
                  'PORTA TRASEIRA E LATERAL (PRIMEIRA DESCARGA)',
                  style: TextStyle(
                    color: AppColors.statusSuccess,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSlotBayCard({
    required SpatialSlot slot,
    required List<DeliveryStop> associatedStops,
    required bool isDark,
    bool isHighPriorityExit = false,
  }) {
    final int totalPackages = associatedStops.fold(0, (acc, s) => acc + s.packages.length);
    final double totalWeight = associatedStops.fold(0.0, (acc, s) => acc + s.packages.fold(0.0, (pAcc, p) => pAcc + p.weightKg));
    final bool hasPackages = totalPackages > 0;

    return InkWell(
      onTap: hasPackages ? () => _showSlotDetailsBottomSheet(context, slot, associatedStops, isDark) : null,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        height: 130,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: isDark ? AppColors.darkSurfaceElevated : AppColors.lightSurfaceElevated,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: hasPackages ? slot.visualColor : (isDark ? AppColors.darkBorder : AppColors.lightBorder),
            width: hasPackages ? 2 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(color: slot.visualColor, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    slot.label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const Spacer(),
            if (hasPackages) ...[
              for (final stop in associatedStops.take(1))
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: slot.visualColor.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    'Parada #${stop.sequenceIndex}',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: slot.visualColor,
                    ),
                  ),
                ),
              const SizedBox(height: 4),
              Text(
                '$totalPackages vol • ${totalWeight.toStringAsFixed(1)} kg',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
                ),
              ),
              Text(
                'Descarregar #${slot.unloadingOrder}',
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: AppColors.statusSuccess,
                ),
              ),
            ] else ...[
              Text(
                'Vazio',
                style: TextStyle(
                  fontSize: 12,
                  color: isDark ? AppColors.darkTextMuted : AppColors.lightTextMuted,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildLoadingSequenceGuide(BuildContext context, List<DeliveryStop> stops, bool isDark) {
    // Sort slots by loading priority: 1 is deepest, 6 is doors
    final List<SpatialSlot> loadSlots = List.from(SpatialSlot.allSlots)
      ..sort((a, b) => a.loadingOrder.compareTo(b.loadingOrder));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
          ),
          child: const Row(
            children: [
              Icon(Icons.info_outline, size: 20, color: AppColors.primaryBlueLight),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Principio LIFO: O ultimo pacote a entrar no veiculo e o primeiro entregue na rota. Carregue o fundo primeiro.',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        for (int i = 0; i < loadSlots.length; i++) ...[
          _buildLoadingStepItem(stepIndex: i + 1, slot: loadSlots[i], stops: stops, isDark: isDark),
          const SizedBox(height: 10),
        ],
      ],
    );
  }

  Widget _buildLoadingStepItem({
    required int stepIndex,
    required SpatialSlot slot,
    required List<DeliveryStop> stops,
    required bool isDark,
  }) {
    final matchingStops = stops.where((s) => s.spatialSlot.type == slot.type).toList();
    final int packageCount = matchingStops.fold(0, (acc, s) => acc + s.packages.length);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: isDark ? AppColors.darkBorder : AppColors.lightBorder),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: slot.visualColor,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Center(
              child: Text(
                '$stepIndex',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: 16,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Carregar: ${slot.label}',
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 2),
                if (matchingStops.isNotEmpty)
                  Text(
                    'Parada #${matchingStops.first.sequenceIndex} (${matchingStops.first.recipientName}) • $packageCount vol',
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  )
                else
                  Text(
                    'Nenhum volume alocado neste setor',
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? AppColors.darkTextMuted : AppColors.lightTextMuted,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: isDark ? AppColors.darkSurfaceElevated : AppColors.lightSurfaceElevated,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              'Descarrega #${slot.unloadingOrder}',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showSlotDetailsBottomSheet(
    BuildContext context,
    SpatialSlot slot,
    List<DeliveryStop> stops,
    bool isDark,
  ) {
    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? AppColors.darkSurface : AppColors.lightSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(color: slot.visualColor, shape: BoxShape.circle),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    slot.label,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(ctx).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                slot.description,
                style: TextStyle(
                  fontSize: 13,
                  color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
                ),
              ),
              const SizedBox(height: 16),
              const Divider(),
              const SizedBox(height: 8),
              const Text(
                'Volumes Alocados Neste Compartimento:',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 10),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: stops.fold(0, (acc, s) => acc + s.packages.length),
                  separatorBuilder: (context, index) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final allPkgs = stops.expand((s) => s.packages).toList();
                    final pkg = allPkgs[index];
                    return Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: isDark ? AppColors.darkSurfaceElevated : AppColors.lightSurfaceElevated,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            pkg.status == PackageStatus.loaded ? Icons.check_circle : Icons.inventory_2_outlined,
                            size: 18,
                            color: pkg.status == PackageStatus.loaded ? AppColors.statusSuccess : AppColors.primaryBlueLight,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  pkg.barcode,
                                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                                ),
                                Text(
                                  pkg.description,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Text(
                            '${pkg.weightKg} kg',
                            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
