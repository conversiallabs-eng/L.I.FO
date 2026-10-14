import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../cargo_scanner/presentation/screens/cargo_scanner_screen.dart';
import '../../../route_manifest/domain/models/spatial_slot.dart';
import '../../../route_manifest/domain/models/delivery_stop.dart';
import '../../../route_manifest/domain/models/package_item.dart';
import '../../../route_manifest/presentation/manifest_controller.dart';
import '../../data/slot_names.dart';

/// Baú interativo: cada quadrado é um compartimento de verdade.
/// Toque abre ações (bipar etiqueta, digitar código, renomear) e a lista
/// de volumes atribuídos. Sem mocks: tudo vem do manifesto ativo.
class VehicleBayScreen extends ConsumerStatefulWidget {
  const VehicleBayScreen({super.key});

  @override
  ConsumerState<VehicleBayScreen> createState() => _VehicleBayScreenState();
}

class _VehicleBayScreenState extends ConsumerState<VehicleBayScreen> {
  int _selectedViewMode = 0; // 0 = Planta Espacial, 1 = Ordem de Carregamento

  String _slotLabel(SpatialSlot slot) {
    final names = ref.watch(slotNamesProvider);
    return SlotNamesNotifier.labelOf(names, slot);
  }

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
      body: manifestState.isLoading
          ? const Center(child: CircularProgressIndicator())
          : (current == null || current.stops.isEmpty)
              ? _buildEmptyState(context, isDark)
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

  Widget _buildEmptyState(BuildContext context, bool isDark) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.local_shipping_outlined,
              size: 56,
              color: isDark ? AppColors.darkTextMuted : AppColors.lightTextMuted,
            ),
            const SizedBox(height: 12),
            Text(
              'Nenhum manifesto ativo',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Importe um manifesto para organizar o baú por compartimento.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Agrupa os VOLUMES pelo compartimento atribuído (bipagem pode mover
  /// um pacote de quadrado sem mudar a parada dele).
  Map<SpatialSlotType, List<PackageItem>> _packagesBySlot(
    List<DeliveryStop> stops,
  ) {
    final map = <SpatialSlotType, List<PackageItem>>{
      for (final s in SpatialSlot.allSlots) s.type: [],
    };
    for (final stop in stops) {
      for (final pkg in stop.packages) {
        map[pkg.spatialSlot.type]?.add(pkg);
      }
    }
    return map;
  }

  Map<String, DeliveryStop> _stopsById(List<DeliveryStop> stops) {
    return {for (final s in stops) s.id: s};
  }

  Widget _buildVehicleFloorplan(
    BuildContext context,
    List<DeliveryStop> stops,
    bool isDark,
  ) {
    final slotPkgs = _packagesBySlot(stops);
    final stopsById = _stopsById(stops);

    Widget bay(SpatialSlotType type, {bool exit = false}) {
      final slot = SpatialSlot.fromType(type);
      return Expanded(
        child: _buildSlotBayCard(
          slot: slot,
          packages: slotPkgs[type] ?? [],
          stopsById: stopsById,
          isDark: isDark,
          isHighPriorityExit: exit,
        ),
      );
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
              bay(SpatialSlotType.fundoEsquerdo),
              const SizedBox(width: 8),
              bay(SpatialSlotType.fundoDireito),
            ],
          ),

          const SizedBox(height: 8),

          // Row 1: Meio
          Row(
            children: [
              bay(SpatialSlotType.meioEsquerdo),
              const SizedBox(width: 8),
              bay(SpatialSlotType.meioDireito),
            ],
          ),

          const SizedBox(height: 8),

          // Row 2: Portas (Immediate Access - Loaded LAST, Unloaded FIRST)
          Row(
            children: [
              bay(SpatialSlotType.portaTraseira, exit: true),
              const SizedBox(width: 8),
              bay(SpatialSlotType.portaLateral, exit: true),
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
    required List<PackageItem> packages,
    required Map<String, DeliveryStop> stopsById,
    required bool isDark,
    bool isHighPriorityExit = false,
  }) {
    final label = _slotLabel(slot);
    final int totalPackages = packages.length;
    final double totalWeight =
        packages.fold(0.0, (acc, p) => acc + p.weightKg);
    final bool hasPackages = totalPackages > 0;
    final stopNumbers = <int>{};
    for (final p in packages) {
      final stop = stopsById[p.stopId];
      if (stop != null) stopNumbers.add(stop.sequenceIndex);
    }
    final orderedNums = stopNumbers.toList()..sort();

    return InkWell(
      // Sempre abre: quadrado vazio também bipaatribui e renomeia.
      onTap: () => _showSlotSheet(context, slot, packages, stopsById, isDark),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        height: 132,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: isDark ? AppColors.darkSurfaceElevated : AppColors.lightSurfaceElevated,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: Colors.black,
            width: hasPackages ? 2.2 : 1.4,
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
                    label,
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
              Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  for (final n in orderedNums.take(2))
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: slot.visualColor.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        'Parada #$n',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          color: slot.visualColor,
                        ),
                      ),
                    ),
                  if (orderedNums.length > 2)
                    Text(
                      '+${orderedNums.length - 2}',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: isDark
                            ? AppColors.darkTextSecondary
                            : AppColors.lightTextSecondary,
                      ),
                    ),
                ],
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
                'Vazio • toque p/ bipar',
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

  Widget _buildLoadingSequenceGuide(
    BuildContext context,
    List<DeliveryStop> stops,
    bool isDark,
  ) {
    // Sort slots by loading priority: 1 is deepest, 6 is doors
    final List<SpatialSlot> loadSlots = List.from(SpatialSlot.allSlots)
      ..sort((a, b) => a.loadingOrder.compareTo(b.loadingOrder));
    final slotPkgs = _packagesBySlot(stops);
    final stopsById = _stopsById(stops);

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
          _buildLoadingStepItem(
            stepIndex: i + 1,
            slot: loadSlots[i],
            packages: slotPkgs[loadSlots[i].type] ?? [],
            stopsById: stopsById,
            isDark: isDark,
          ),
          const SizedBox(height: 10),
        ],
      ],
    );
  }

  Widget _buildLoadingStepItem({
    required int stepIndex,
    required SpatialSlot slot,
    required List<PackageItem> packages,
    required Map<String, DeliveryStop> stopsById,
    required bool isDark,
  }) {
    final stopNames = <String>{};
    for (final p in packages) {
      final stop = stopsById[p.stopId];
      if (stop != null) {
        stopNames.add('#${stop.sequenceIndex} ${stop.recipientName}');
      }
    }

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _showSlotSheet(context, slot, packages, stopsById, isDark),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.black, width: 1.4),
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
                    'Carregar: ${_slotLabel(slot)}',
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  if (packages.isNotEmpty)
                    Text(
                      '${stopNames.take(2).join(' • ')}${stopNames.length > 2 ? ' • +${stopNames.length - 2}' : ''} (${packages.length} vol)',
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
      ),
    );
  }

  /// Renomeia o compartimento (ex.: "Geladeira", "Corredor").
  Future<void> _renameSlotDialog(
    BuildContext context,
    SpatialSlot slot,
    bool isDark,
  ) async {
    final current = SlotNamesNotifier.labelOf(
      ref.read(slotNamesProvider),
      slot,
    );
    final ctrl = TextEditingController(text: current == slot.label ? '' : current);
    final result = await showDialog<String>(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: isDark ? AppColors.darkSurface : AppColors.lightSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          'Renomear local',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Nome atual: ${SlotNamesNotifier.labelOf(ref.read(slotNamesProvider), slot)}',
              style: TextStyle(
                fontSize: 12,
                color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: ctrl,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => Navigator.pop(dCtx, ctrl.text.trim()),
              decoration: InputDecoration(
                hintText: slot.label,
                labelText: 'Nome do local',
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dCtx, ctrl.text.trim()),
            child: const Text('Salvar'),
          ),
        ],
      ),
    );
    if (result != null && context.mounted) {
      await ref.read(slotNamesProvider.notifier).rename(slot.type, result);
      HapticFeedback.lightImpact();
    }
  }

  /// Digita o rastreio à mão (etiqueta rasurada) e atribui ao compartimento.
  Future<void> _typeCodeDialog(
    BuildContext context,
    SpatialSlot slot,
    bool isDark,
  ) async {
    final ctrl = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: isDark ? AppColors.darkSurface : AppColors.lightSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text(
          'Digitar rastreio',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Para etiqueta rasurada que a câmera não lê.',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: ctrl,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => Navigator.pop(dCtx, ctrl.text.trim()),
              decoration: const InputDecoration(
                hintText: 'Ex: BR2636935367A',
                labelText: 'Código de rastreio',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(dCtx, ctrl.text.trim()),
            child: const Text('Atribuir'),
          ),
        ],
      ),
    );
    if (code == null || code.isEmpty || !context.mounted) return;
    final label = _slotLabel(slot);
    final pkg = await ref
        .read(manifestControllerProvider.notifier)
        .assignPackageToSlot(barcode: code, slot: slot);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          pkg != null
              ? '$code → $label (${pkg.status == PackageStatus.loaded ? 'carregado' : 'atribuído'})'
              : '$code não está no manifesto.',
        ),
        backgroundColor:
            pkg != null ? AppColors.statusSuccess : AppColors.statusDanger,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// Ações do quadrado: bipar, digitar, renomear + volumes atribuídos.
  void _showSlotSheet(
    BuildContext context,
    SpatialSlot slot,
    List<PackageItem> packages,
    Map<String, DeliveryStop> stopsById,
    bool isDark,
  ) {
    final label = _slotLabel(slot);
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: isDark ? AppColors.darkSurface : AppColors.lightSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 12,
            bottom: MediaQuery.of(ctx).padding.bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 38,
                  height: 4.5,
                  decoration: BoxDecoration(
                    color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Container(
                    width: 14,
                    height: 14,
                    decoration: BoxDecoration(
                      color: slot.visualColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      label,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Renomear local',
                    icon: const Icon(Icons.edit_outlined, size: 20),
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      _renameSlotDialog(context, slot, isDark);
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(ctx).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '${slot.description} • Carrega #${slot.loadingOrder} • Descarrega #${slot.unloadingOrder}',
                style: TextStyle(
                  fontSize: 12,
                  color: isDark
                      ? AppColors.darkTextSecondary
                      : AppColors.lightTextSecondary,
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.qr_code_scanner, size: 18),
                      label: const Text('Bipar etiqueta'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primaryBlue,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => CargoScannerScreen(
                              assignToSlot: slot.type,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.keyboard_alt_outlined, size: 18),
                      label: const Text('Digitar código'),
                      style: OutlinedButton.styleFrom(
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                      onPressed: () {
                        Navigator.of(ctx).pop();
                        _typeCodeDialog(context, slot, isDark);
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                'Volumes neste local (${packages.length}):',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              if (packages.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Center(
                    child: Text(
                      'Vazio — bipe uma etiqueta ou digite o rastreio para atribuir volumes aqui.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark
                            ? AppColors.darkTextSecondary
                            : AppColors.lightTextSecondary,
                      ),
                    ),
                  ),
                )
              else
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: packages.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: 8),
                    itemBuilder: (_, index) {
                      final pkg = packages[index];
                      final stop = stopsById[pkg.stopId];
                      return Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: isDark
                              ? AppColors.darkSurfaceElevated
                              : AppColors.lightSurfaceElevated,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.black, width: 1),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              pkg.status == PackageStatus.loaded
                                  ? Icons.check_circle
                                  : Icons.inventory_2_outlined,
                              size: 18,
                              color: pkg.status == PackageStatus.loaded
                                  ? AppColors.statusSuccess
                                  : AppColors.primaryBlueLight,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    pkg.barcode,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                    ),
                                  ),
                                  Text(
                                    stop != null
                                        ? 'Parada #${stop.sequenceIndex} • ${stop.recipientName}'
                                        : pkg.description,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: isDark
                                          ? AppColors.darkTextSecondary
                                          : AppColors.lightTextSecondary,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            Text(
                              '${pkg.weightKg} kg',
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 12,
                              ),
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
