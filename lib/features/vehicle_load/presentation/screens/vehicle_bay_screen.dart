import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../../../core/theme/app_colors.dart';
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
      ),
      body: manifestState.isLoading
          ? const Center(child: CircularProgressIndicator())
          : (current == null || current.stops.isEmpty)
              ? _buildEmptyState(context, isDark)
              // A sequência de carga já sai da ordem da rota (a parada #1 é a
              // primeira entrega e por isso fica na porta traseira), então a
              // tela mostra só a planta do baú.
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: _buildVehicleFloorplan(context, current.stops, isDark),
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

    Widget bay(SpatialSlotType type) {
      final slot = SpatialSlot.fromType(type);
      // A planta só mostra o que o usuário realmente colocou no baú. O
      // compartimento automático do LIFO não é uma colocação real.
      final placed = (slotPkgs[type] ?? [])
          .where((p) => p.slotUserAssigned)
          .toList();
      return Expanded(
        child: _buildSlotBayCard(
          slot: slot,
          packages: placed,
          stopsById: stopsById,
          isDark: isDark,
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
              bay(SpatialSlotType.portaTraseira),
              const SizedBox(width: 8),
              bay(SpatialSlotType.portaLateral),
            ],
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
  }) {
    final label = _slotLabel(slot);
    final int totalPackages = packages.length;
    final bool hasKnownWeight = packages.any((p) => p.weightKg != null);
    final double totalWeight = packages.fold(
      0.0,
      (acc, p) => acc + (p.weightKg ?? 0),
    );
    final bool hasPackages = totalPackages > 0;
    final stopNumbers = <int>{};
    for (final p in packages) {
      final stop = stopsById[p.stopId];
      if (stop != null) stopNumbers.add(stop.sequenceIndex);
    }
    final orderedNums = stopNumbers.toList()..sort();

    return InkWell(
      // Sempre abre: quadrado vazio também bipaatribui e renomeia.
      onTap: () => _showSlotSheet(context, slot, isDark),
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
                  decoration: BoxDecoration(color: AppColors.primaryBlue, shape: BoxShape.circle),
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
              // Só as contagens: com muitos volumes a lista de paradas estoura
              // o quadrado — quem quiser a lista completa toca e abre o painel.
              Text(
                '${orderedNums.length} ${orderedNums.length == 1 ? 'parada' : 'paradas'} • $totalPackages vol',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                // Sem peso no manifesto, mostra só o descarrega — sem "0.0 kg".
                hasKnownWeight
                    ? '${totalWeight.toStringAsFixed(1)} kg • Descarregar #${slot.unloadingOrder}'
                    : 'Descarregar #${slot.unloadingOrder}',
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
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
    final code = await showGeneralDialog<String>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Digitar rastreio',
      barrierColor: Colors.black.withValues(alpha: 0.6),
      transitionDuration: const Duration(milliseconds: 240),
      pageBuilder: (dCtx, _, _) => AlertDialog(
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
      transitionBuilder: (_, animation, _, child) => FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.92, end: 1.0).animate(
            CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutBack,
              reverseCurve: Curves.easeIn,
            ),
          ),
          child: child,
        ),
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
            pkg != null ? AppColors.primaryBlue : AppColors.statusDanger,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// Abre o painel do compartimento. A altura é fixa e a lista de volumes
  /// rola por conta própria; bipar/digitar entra na lista na hora.
  void _showSlotSheet(BuildContext context, SpatialSlot slot, bool isDark) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: isDark ? AppColors.darkSurface : AppColors.lightSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _SlotSheet(
        slot: slot,
        onRename: () => _renameSlotDialog(context, slot, isDark),
        onTypeCode: () => _typeCodeDialog(context, slot, isDark),
      ),
    );
  }
}

/// Painel de um compartimento do baú. A lista de volumes tem rolagem própria
/// e a câmera abre numa telinha flutuante sobre o painel — bipou, já entrou.
class _SlotSheet extends ConsumerStatefulWidget {
  final SpatialSlot slot;
  final VoidCallback onRename;
  final VoidCallback onTypeCode;

  const _SlotSheet({
    required this.slot,
    required this.onRename,
    required this.onTypeCode,
  });

  @override
  ConsumerState<_SlotSheet> createState() => _SlotSheetState();
}

class _SlotSheetState extends ConsumerState<_SlotSheet> {
  MobileScannerController? _camera;
  bool _cameraOpen = false;
  bool _processing = false;
  String _lastCode = '';
  DateTime? _lastScanAt;
  int _addedCount = 0;
  String? _feedback;
  bool _feedbackOk = true;

  SpatialSlot get _slot => widget.slot;

  @override
  void dispose() {
    _camera?.dispose();
    super.dispose();
  }

  /// Volumes que o usuário realmente colocou neste compartimento.
  List<PackageItem> _placedVolumes(List<DeliveryStop> stops) {
    final result = <PackageItem>[];
    for (final stop in stops) {
      for (final pkg in stop.packages) {
        if (pkg.slotUserAssigned && pkg.spatialSlot.type == _slot.type) {
          result.add(pkg);
        }
      }
    }
    return result;
  }

  Map<String, DeliveryStop> _stopsById(List<DeliveryStop> stops) =>
      {for (final s in stops) s.id: s};

  void _openCamera() {
    _camera ??= MobileScannerController(
      detectionSpeed: DetectionSpeed.normal,
      facing: CameraFacing.back,
    );
    setState(() {
      _cameraOpen = true;
      _feedback = null;
    });
  }

  Future<void> _closeCamera() async {
    await _camera?.stop();
    if (!mounted) return;
    setState(() => _cameraOpen = false);
  }

  void _onDetect(BarcodeCapture capture) {
    final raw =
        capture.barcodes.isEmpty ? null : capture.barcodes.first.rawValue;
    if (raw == null || raw.trim().isEmpty) return;
    final code = raw.trim();
    final now = DateTime.now();
    // A câmera repete o mesmo código várias vezes por segundo.
    if (code == _lastCode &&
        _lastScanAt != null &&
        now.difference(_lastScanAt!).inMilliseconds < 1500) {
      return;
    }
    _lastScanAt = now;
    _addCode(code);
  }

  /// Atribui o código a este compartimento. Bipou, já entrou na lista.
  Future<PackageItem?> _addCode(String code) async {
    final clean = code.trim();
    if (clean.isEmpty || _processing) return null;
    _processing = true;
    _lastCode = clean;

    final pkg = await ref
        .read(manifestControllerProvider.notifier)
        .assignPackageToSlot(barcode: clean, slot: _slot);

    if (!mounted) {
      _processing = false;
      return pkg;
    }
    setState(() {
      _processing = false;
      _feedbackOk = pkg != null;
      _feedback =
          pkg != null ? '✓ $clean adicionado' : '$clean não está no manifesto';
      if (pkg != null) _addedCount++;
    });
    return pkg;
  }

  /// "X" do volume: tira do compartimento (o usuário se enganou). O volume
  /// volta ao compartimento automático e segue marcado como carregado.
  Future<void> _removeVolume(PackageItem pkg) async {
    final ok = await ref
        .read(manifestControllerProvider.notifier)
        .unassignPackageFromSlot(pkg.barcode);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Não foi possível remover este volume.'),
          backgroundColor: AppColors.statusDanger,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final names = ref.watch(slotNamesProvider);
    final stops =
        ref.watch(manifestControllerProvider).currentVersion?.stops ??
            const <DeliveryStop>[];
    final stopsById = _stopsById(stops);
    final volumes = _placedVolumes(stops);
    final label = SlotNamesNotifier.labelOf(names, _slot);
    final media = MediaQuery.of(context);

    return SizedBox(
      height: media.size.height * 0.85,
      child: Stack(
        children: [
          Padding(
            padding: EdgeInsets.only(
              left: 20,
              right: 20,
              top: 12,
              bottom: 16 + MediaQuery.viewPaddingOf(context).bottom,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 38,
                    height: 4.5,
                    decoration: BoxDecoration(
                      color:
                          isDark ? AppColors.darkBorder : AppColors.lightBorder,
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
                      decoration: const BoxDecoration(
                        color: AppColors.primaryBlue,
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
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Renomear local',
                      icon: const Icon(Icons.edit_outlined, size: 20),
                      onPressed: widget.onRename,
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${_slot.description} • Carrega #${_slot.loadingOrder} • Descarrega #${_slot.unloadingOrder}',
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
                        onPressed: _openCamera,
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
                        onPressed: widget.onTypeCode,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  'Volumes neste local (${volumes.length}):',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                Expanded(
                  child: volumes.isEmpty
                      ? Center(
                          child: Text(
                            'Nada aqui ainda.\nBipe uma etiqueta ou digite o rastreio.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 12,
                              color: isDark
                                  ? AppColors.darkTextSecondary
                                  : AppColors.lightTextSecondary,
                            ),
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.only(bottom: 8),
                          itemCount: volumes.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 8),
                          itemBuilder: (_, index) {
                            final pkg = volumes[index];
                            return _buildVolumeTile(
                              pkg,
                              stopsById[pkg.stopId],
                              isDark,
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
          if (_cameraOpen) _buildCameraPanel(isDark, label),
        ],
      ),
    );
  }

  Widget _buildVolumeTile(
    PackageItem pkg,
    DeliveryStop? stop,
    bool isDark,
  ) {
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
          const Icon(
            Icons.inventory_2_outlined,
            size: 18,
            color: AppColors.primaryBlue,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
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
          if (pkg.weightKg != null)
            Text(
              '${pkg.weightKg} kg',
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12),
            ),
          IconButton(
            tooltip: 'Excluir do compartimento',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close, size: 20),
            onPressed: () => _removeVolume(pkg),
          ),
        ],
      ),
    );
  }

  /// Telinha da câmera flutuando sobre o painel: bipou, já entrou na lista.
  /// Entra com o fundo escurecendo em fade e um leve "pop" no card.
  Widget _buildCameraPanel(bool isDark, String label) {
    return Positioned.fill(
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: 1),
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
        builder: (context, t, child) => Container(
          color: Colors.black.withValues(alpha: 0.7 * t),
          alignment: Alignment.center,
          padding: const EdgeInsets.all(20),
          child: Opacity(
            opacity: t,
            child: Transform.scale(
              scale: 0.9 + 0.1 * t,
              child: child,
            ),
          ),
        ),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color:
                isDark ? AppColors.darkSurfaceElevated : AppColors.lightSurface,
            borderRadius: BorderRadius.circular(18),
            boxShadow: const [
              BoxShadow(
                color: Colors.black38,
                blurRadius: 18,
                offset: Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.qr_code_scanner,
                    size: 18,
                    color: AppColors.primaryBlue,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Bipando para $label',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: _closeCamera,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: SizedBox(
                  width: 280,
                  height: 200,
                  child: MobileScanner(
                    controller: _camera!,
                    onDetect: _onDetect,
                    errorBuilder: (_, _) => Container(
                      color: Colors.black,
                      alignment: Alignment.center,
                      child: const Padding(
                        padding: EdgeInsets.all(12),
                        child: Text(
                          'Sem acesso à câmera. Use "Digitar código".',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white, fontSize: 12),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 18,
                child: Text(
                  _feedback ?? 'Aponte para a etiqueta',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: _feedback == null
                        ? (isDark
                            ? AppColors.darkTextSecondary
                            : AppColors.lightTextSecondary)
                        : (_feedbackOk
                            ? AppColors.primaryBlue
                            : AppColors.statusDanger),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                '$_addedCount adicionado(s) neste compartimento',
                style: TextStyle(
                  fontSize: 11,
                  color: isDark
                      ? AppColors.darkTextMuted
                      : AppColors.lightTextMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
