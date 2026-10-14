import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../route_manifest/presentation/manifest_controller.dart';
import '../../../route_manifest/presentation/screens/add_stop_sheet.dart';
import '../../../route_manifest/domain/models/delivery_stop.dart';
import '../../../route_manifest/domain/models/spatial_slot.dart';
import '../../../../core/services/geocoding_service.dart';

class CargoScannerScreen extends ConsumerStatefulWidget {
  /// Quando definido, cada bip atribui o volume a este compartimento do baú
  /// (modo "bipar por quadrado") em vez de só marcar como carregado.
  final SpatialSlotType? assignToSlot;

  const CargoScannerScreen({super.key, this.assignToSlot});

  @override
  ConsumerState<CargoScannerScreen> createState() => _CargoScannerScreenState();
}

class _CargoScannerScreenState extends ConsumerState<CargoScannerScreen> {
  late final MobileScannerController _scannerController;
  bool _isProcessing = false;
  String _lastProcessedBarcode = '';
  DateTime? _lastScanTime;
  bool _isTorchOn = false;
  bool _showScannedCard = false;

  @override
  void initState() {
    super.initState();
    _scannerController = MobileScannerController(
      detectionSpeed: DetectionSpeed.normal,
      facing: CameraFacing.back,
      torchEnabled: false,
    );
  }

  @override
  void dispose() {
    _scannerController.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) async {
    if (_isProcessing) return;

    final barcodes = capture.barcodes;
    if (barcodes.isEmpty) return;

    final rawValue = barcodes.first.rawValue;
    if (rawValue == null || rawValue.trim().isEmpty) return;

    final trimmed = rawValue.trim();

    // Debounce rápido (800ms) para permitir re-bipar o mesmo pacote a qualquer momento
    final now = DateTime.now();
    if (_lastProcessedBarcode == trimmed &&
        _lastScanTime != null &&
        now.difference(_lastScanTime!).inMilliseconds < 800) {
      return;
    }

    _isProcessing = true;
    _lastProcessedBarcode = trimmed;
    _lastScanTime = now;

    final found = await ref.read(manifestControllerProvider.notifier).handleInstantScan(trimmed);

    if (!mounted) {
      _isProcessing = false;
      return;
    }

    if (found) {
      await _assignSlotIfNeeded(trimmed);
      if (!mounted) {
        _isProcessing = false;
        return;
      }
      setState(() {
        _showScannedCard = true;
      });
    } else {
      await _showUnknownBarcodeModal(trimmed);
    }

    if (mounted) {
      setState(() {
        _isProcessing = false;
      });
    }
  }

  /// Modo "bipar por quadrado" do baú: move o volume lido para o
  /// compartimento escolhido, marcando-o como carregado (bipar = carregar).
  /// Fora desse modo é no-op — o fluxo padrão apenas confere a carga.
  Future<void> _assignSlotIfNeeded(String barcode) async {
    final slotType = widget.assignToSlot;
    if (slotType == null) return;
    await ref.read(manifestControllerProvider.notifier).assignPackageToSlot(
          barcode: barcode,
          slot: SpatialSlot.fromType(slotType),
        );
  }

  /// Modal mostrado quando o QR/barcode lido não está no manifesto.
  /// Oferece duas opções: adicionar nova parada (com barcode pré-preenchido)
  /// ou vincular a uma parada existente.
  Future<void> _showUnknownBarcodeModal(String barcode) async {
    final stops = ref.read(manifestControllerProvider).currentVersion?.stops ?? [];

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _UnknownBarcodeSheet(
        barcode: barcode,
        stops: stops,
        onAddNewStop: () async {
          Navigator.of(ctx).pop();
          final ok = await AddStopSheet.show(
            context,
            initialBarcode: barcode,
          );
          if (ok == true && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Nova parada adicionada com código $barcode!'),
                backgroundColor: AppColors.circuitGreen,
                duration: const Duration(seconds: 2),
              ),
            );
          }
        },
        onLinkToStop: (stop) async {
          Navigator.of(ctx).pop();
          await _linkBarcodeToStop(barcode, stop);
        },
      ),
    );
  }

  /// Vincula o barcode escaneado como novo pacote de uma parada existente.
  Future<void> _linkBarcodeToStop(String barcode, DeliveryStop stop) async {
    final ok = await ref.read(manifestControllerProvider.notifier).addPackageToStop(
      stopId: stop.id,
      barcode: barcode,
      description: 'Volume $barcode',
      weightKg: null,
    );

    if (!mounted) return;

    if (ok) {
      HapticFeedback.mediumImpact();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Código $barcode vinculado à parada #${stop.sequenceIndex} — ${stop.recipientName}'),
          backgroundColor: AppColors.circuitGreen,
          duration: const Duration(seconds: 3),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Falha ao vincular $barcode à parada #${stop.sequenceIndex}.'),
          backgroundColor: AppColors.circuitRed,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  void _showManualEntryDialog() {
    final textController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) {
        final isDark = Theme.of(ctx).brightness == Brightness.dark;
        return AlertDialog(
          backgroundColor: isDark ? AppColors.darkSurface : AppColors.lightSurface,
          title: const Text('Entrada Manual de Codigo'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Digite o identificador do pacote caso o codigo de barras esteja danificado.',
                style: TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: textController,
                autofocus: true,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(
                  labelText: 'Codigo / Barcode',
                  hintText: 'Ex: LF-882190',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancelar'),
            ),
            ElevatedButton(
              onPressed: () async {
                final code = textController.text.trim();
                if (code.isNotEmpty) {
                  Navigator.of(ctx).pop();
                  final found = await ref.read(manifestControllerProvider.notifier).handleInstantScan(code);
                  if (!found && mounted) {
                    await _showUnknownBarcodeModal(code);
                  }
                }
              },
              child: const Text('Confirmar'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final manifestState = ref.watch(manifestControllerProvider);
    final currentManifest = manifestState.currentVersion;

    final loadedCount = currentManifest?.loadedPackagesCount ?? 0;
    final totalCount = currentManifest?.totalPackagesInStops ?? 0;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Camera viewport
          MobileScanner(
            controller: _scannerController,
            onDetect: _onDetect,
            errorBuilder: (context, error) {
              return Center(
                child: Container(
                  margin: const EdgeInsets.all(24),
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: AppColors.darkSurface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: AppColors.statusDanger, width: 1.5),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.videocam_off_outlined, color: AppColors.statusDanger, size: 48),
                      const SizedBox(height: 12),
                      const Text(
                        'Falha no Acesso a Camera',
                        style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Verifique as permissoes de camera ou utilize a entrada manual de codigos.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white.withValues(alpha: 0.8), fontSize: 13),
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton.icon(
                        onPressed: _showManualEntryDialog,
                        icon: const Icon(Icons.keyboard_alt_outlined),
                        label: const Text('Digitar Codigo Manual'),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),

          // Viewfinder central com máscara cinza translúcida ao redor da câmera e contorno em azul limpo
          LayoutBuilder(
            builder: (context, constraints) {
              const double boxW = 280.0;
              const double boxH = 200.0;
              final double left = (constraints.maxWidth - boxW) / 2;
              final double top = (constraints.maxHeight - boxH) / 2;
              final scanRect = Rect.fromLTWH(left, top, boxW, boxH);

              return Stack(
                children: [
                  // Máscara cinza translúcida ao lado do leitor (escurece a câmera ao redor)
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _ScannerCutoutPainter(
                        scanWindow: scanRect,
                        borderRadius: 16,
                        overlayColor: const Color(0x73000000),
                      ),
                    ),
                  ),

                  // Moldura do leitor com contorno azul limpo (estilo Circuit, sem neon)
                  Positioned(
                    left: left,
                    top: top,
                    width: boxW,
                    height: boxH,
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: const Color(0xFF2563EB),
                          width: 2.5,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),

          // Top Header HUD: Progress & Controls
          SafeArea(
            child: Column(
              children: [
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white24, width: 1),
                  ),
                  child: Row(
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'CONFERENCIA DE CARGA',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.0,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '$loadedCount / $totalCount pacotes bipados',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      const Spacer(),
                      // Flashlight toggle
                      IconButton(
                        tooltip: 'Lanterna',
                        onPressed: () async {
                          await _scannerController.toggleTorch();
                          setState(() {
                            _isTorchOn = !_isTorchOn;
                          });
                        },
                        icon: Icon(
                          _isTorchOn ? Icons.flash_on : Icons.flash_off,
                          color: _isTorchOn ? AppColors.accentAmber : Colors.white,
                        ),
                      ),
                      // Manual entry fallback
                      IconButton(
                        tooltip: 'Entrada Manual',
                        onPressed: _showManualEntryDialog,
                        icon: const Icon(Icons.keyboard_alt_outlined, color: Colors.white),
                      ),
                    ],
                  ),
                ),

                const Spacer(),

                // Só aparece quando bipar o pacote (estilo Circuit)
                if (_showScannedCard && manifestState.lastScannedStop != null)
                  _buildCircuitStyleBottomSheet(
                    stop: manifestState.lastScannedStop!,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Card exatamente no estilo do Circuit: fundo branco, sem neon, azul clássico
  Widget _buildCircuitStyleBottomSheet({
    required DeliveryStop stop,
  }) {
    final firstAddressLine = stop.address.split(',').first.trim();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 20),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        boxShadow: [
          BoxShadow(
            color: Colors.black26,
            blurRadius: 16,
            offset: Offset(0, -3),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Handle bar cinza
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            // Linha com ícone e texto da parada / endereço
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  margin: const EdgeInsets.only(top: 2),
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: const Color(0xFF2563EB).withValues(alpha: 0.10),
                    border: Border.all(
                      color: const Color(0xFF2563EB).withValues(alpha: 0.35),
                      width: 1.2,
                    ),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Center(
                    child: Text(
                      '${stop.sequenceIndex}',
                      style: const TextStyle(
                        color: Color(0xFF2563EB),
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        height: 1,
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
                        'Parada ${stop.sequenceIndex} no endereço $firstAddressLine',
                        style: const TextStyle(
                          color: Color(0xFF111827),
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        stop.address,
                        style: const TextStyle(
                          color: Color(0xFF6B7280),
                          fontSize: 13,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                GestureDetector(
                  onTap: () {
                    setState(() {
                      _showScannedCard = false;
                    });
                  },
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(Icons.close, size: 20, color: Color(0xFF9CA3AF)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            // Botão Ir para a parada (navegação interna)
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton.icon(
                onPressed: () {
                  // Fecha o scanner e sinaliza ao dashboard para iniciar navegação
                  Navigator.of(context).pop({'navigateTo': stop.id});
                },
                icon: const Icon(Icons.navigation_rounded, size: 20),
                label: const Text(
                  'Ir para a parada',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF16A34A),
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            // Botão Editar endereço
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                onPressed: () => _showEditAddressModal(context, stop),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2563EB),
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text(
                  'Editar endereço',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: Text(
                'Ao editar o endereço a rota será reotimizada',
                style: TextStyle(
                  color: Colors.grey.shade500,
                  fontSize: 12,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showEditAddressModal(BuildContext context, DeliveryStop stop) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _EditAddressSheet(stop: stop),
    );
  }
}

/// Modal inferior para edição de endereço com geocodificação e reotimização automática
class _EditAddressSheet extends ConsumerStatefulWidget {
  final DeliveryStop stop;

  const _EditAddressSheet({required this.stop});

  @override
  ConsumerState<_EditAddressSheet> createState() => _EditAddressSheetState();
}

class _EditAddressSheetState extends ConsumerState<_EditAddressSheet> {
  late final TextEditingController _addressController;
  final GeocodingService _geocodingService = GeocodingService();
  List<GeocodingResult> _suggestions = [];
  bool _isSearching = false;
  bool _isSaving = false;
  double? _selectedLat;
  double? _selectedLng;

  @override
  void initState() {
    super.initState();
    _addressController = TextEditingController(text: widget.stop.address);
    _selectedLat = widget.stop.latitude;
    _selectedLng = widget.stop.longitude;
  }

  @override
  void dispose() {
    _addressController.dispose();
    super.dispose();
  }

  Future<void> _search(String query) async {
    if (query.trim().length < 4) {
      if (mounted) setState(() => _suggestions = []);
      return;
    }
    setState(() => _isSearching = true);
    try {
      final results = await _geocodingService.searchAddress(query);
      if (mounted) {
        setState(() {
          _suggestions = results;
          _isSearching = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isSearching = false);
    }
  }

  Future<void> _saveAndReoptimize() async {
    final newAddress = _addressController.text.trim();
    if (newAddress.isEmpty) return;

    setState(() => _isSaving = true);
    final success = await ref
        .read(manifestControllerProvider.notifier)
        .editStopAddressAndReoptimize(
          stopId: widget.stop.id,
          newAddress: newAddress,
          newLat: _selectedLat,
          newLng: _selectedLng,
        );

    if (mounted) {
      setState(() => _isSaving = false);
      if (success) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF1E293B),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            content: const Row(
              children: [
                Icon(Icons.check_circle, color: Color(0xFF2563EB)),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Endereço atualizado! Rota reotimizada com sucesso.',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: AppColors.statusDanger,
            content: Text('Erro ao atualizar endereço e reotimizar rota.'),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.fromLTRB(20, 16, 20, 20 + bottomInset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Handle bar
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Header
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: const BoxDecoration(
                  color: Color(0xFFEFF6FF),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.edit_location_alt_rounded,
                  color: Color(0xFF2563EB),
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Editar Endereço (Parada #${widget.stop.sequenceIndex})',
                      style: const TextStyle(
                        color: Color(0xFF111827),
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      widget.stop.recipientName,
                      style: TextStyle(
                        color: Colors.grey.shade600,
                        fontSize: 12,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close, color: Colors.grey),
              ),
            ],
          ),

          const SizedBox(height: 14),

          // Notice box
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFFF3F4F6),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Row(
              children: [
                Icon(Icons.info_outline, color: Color(0xFF2563EB), size: 16),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Ao confirmar, a rota será reotimizada automaticamente a partir da sua posição.',
                    style: TextStyle(color: Color(0xFF4B5563), fontSize: 12),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // Text Field
          TextField(
            controller: _addressController,
            style: const TextStyle(color: Color(0xFF111827), fontSize: 14),
            decoration: InputDecoration(
              labelText: 'Endereço completo',
              labelStyle: TextStyle(color: Colors.grey.shade600),
              hintText: 'Ex: Rodovia SC 401, 121, Florianópolis',
              hintStyle: TextStyle(color: Colors.grey.shade400),
              filled: true,
              fillColor: Colors.grey.shade50,
              prefixIcon: const Icon(Icons.place_outlined, color: Color(0xFF2563EB)),
              suffixIcon: _isSearching
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF2563EB)),
                      ),
                    )
                  : IconButton(
                      icon: const Icon(Icons.search, color: Color(0xFF2563EB)),
                      onPressed: () => _search(_addressController.text),
                    ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.grey.shade300),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFF2563EB), width: 2),
              ),
            ),
            onChanged: (val) {
              _selectedLat = null;
              _selectedLng = null;
              _search(val);
            },
          ),

          // Suggestions list if available
          if (_suggestions.isNotEmpty) ...[
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 160),
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.grey.shade200),
                ),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: _suggestions.length,
                  separatorBuilder: (context, index) => const Divider(height: 1, color: Colors.grey),
                  itemBuilder: (ctx, i) {
                    final item = _suggestions[i];
                    return ListTile(
                      dense: true,
                      leading: const Icon(Icons.location_on, color: Color(0xFF2563EB), size: 18),
                      title: Text(
                        item.displayName,
                        style: const TextStyle(color: Color(0xFF111827), fontSize: 12),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () {
                        setState(() {
                          _addressController.text = item.displayName;
                          _selectedLat = item.latitude;
                          _selectedLng = item.longitude;
                          _suggestions = [];
                        });
                      },
                    );
                  },
                ),
              ),
            ),
          ],

          const SizedBox(height: 18),

          // Confirm and Reoptimize button
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton(
              onPressed: _isSaving ? null : _saveAndReoptimize,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2563EB),
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: _isSaving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Text(
                      'Salvar e Reotimizar Rota',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Modal de código desconhecido ─────────────────────────────────────────────

class _UnknownBarcodeSheet extends StatefulWidget {
  final String barcode;
  final List<DeliveryStop> stops;
  final VoidCallback onAddNewStop;
  final void Function(DeliveryStop stop) onLinkToStop;

  const _UnknownBarcodeSheet({
    required this.barcode,
    required this.stops,
    required this.onAddNewStop,
    required this.onLinkToStop,
  });

  @override
  State<_UnknownBarcodeSheet> createState() => _UnknownBarcodeSheetState();
}

class _UnknownBarcodeSheetState extends State<_UnknownBarcodeSheet> {
  bool _showStopList = false;
  String _searchQuery = '';

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF0F172A) : Colors.white;
    final surface = isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC);
    final textPrimary = isDark ? Colors.white : const Color(0xFF0F172A);
    final textSub = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
    final border = isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0);

    final filteredStops = widget.stops.where((s) {
      if (_searchQuery.isEmpty) return true;
      final q = _searchQuery.toLowerCase();
      return s.recipientName.toLowerCase().contains(q) ||
          s.address.toLowerCase().contains(q) ||
          s.sequenceIndex.toString().contains(q);
    }).toList();

    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).padding.bottom + 8,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle bar
          const SizedBox(height: 12),
          Container(
            width: 38,
            height: 4.5,
            decoration: BoxDecoration(
              color: border,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(height: 16),

          // Header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFFF59E0B).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: const Color(0xFFF59E0B).withValues(alpha: 0.5)),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.qr_code_2, size: 14, color: Color(0xFFF59E0B)),
                          SizedBox(width: 4),
                          Text(
                            'CÓDIGO NÃO ENCONTRADO',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                              color: Color(0xFFF59E0B),
                              letterSpacing: 0.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  widget.barcode,
                  style: TextStyle(
                    color: textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Este código não está cadastrado no manifesto. O que deseja fazer?',
                  style: TextStyle(color: textSub, fontSize: 13),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          if (!_showStopList) ...[
            // Option 1: Nova Parada
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _OptionCard(
                icon: Icons.add_location_alt_rounded,
                iconColor: AppColors.circuitGreen,
                title: 'Adicionar Nova Parada',
                subtitle: 'Abre o formulário com o código pré-preenchido para você informar o destinatário e endereço.',
                isDark: isDark,
                onTap: widget.onAddNewStop,
              ),
            ),
            const SizedBox(height: 10),

            // Option 2: Vincular a parada existente
            if (widget.stops.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: _OptionCard(
                  icon: Icons.link_rounded,
                  iconColor: AppColors.circuitBlueGlow,
                  title: 'Vincular a Parada Existente',
                  subtitle: 'Associa este código como volume de uma parada já cadastrada na rota.',
                  isDark: isDark,
                  onTap: () => setState(() => _showStopList = true),
                ),
              ),
            const SizedBox(height: 10),

            // Cancel
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('Cancelar', style: TextStyle(color: textSub)),
            ),
            const SizedBox(height: 8),
          ] else ...[
            // Stop selector list
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: TextField(
                autofocus: true,
                onChanged: (v) => setState(() => _searchQuery = v),
                style: TextStyle(color: textPrimary, fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'Buscar por nome, endereço ou número...',
                  hintStyle: TextStyle(color: textSub, fontSize: 13),
                  prefixIcon: const Icon(Icons.search, size: 20),
                  filled: true,
                  fillColor: surface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: border),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: border),
                  ),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                ),
              ),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: filteredStops.length,
                separatorBuilder: (context, index) => Divider(height: 1, color: border),
                itemBuilder: (ctx, i) {
                  final stop = filteredStops[i];
                  final isCompleted = stop.status == StopStatus.completed;
                  final isFailed = stop.status == StopStatus.failed;
                  return ListTile(
                    dense: true,
                    leading: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: isCompleted
                            ? const Color(0xFF16A34A)
                            : isFailed
                                ? const Color(0xFFDC2626)
                                : AppColors.circuitBlue,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Center(
                        child: Text(
                          '${stop.sequenceIndex}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                    title: Text(
                      stop.recipientName,
                      style: TextStyle(
                        color: textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      stop.address,
                      style: TextStyle(color: textSub, fontSize: 11),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: AppColors.circuitBlue.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: AppColors.circuitBlueGlow.withValues(alpha: 0.4)),
                      ),
                      child: const Text(
                        'Vincular',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: AppColors.circuitBlueGlow,
                        ),
                      ),
                    ),
                    onTap: () => widget.onLinkToStop(stop),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => setState(() {
                _showStopList = false;
                _searchQuery = '';
              }),
              child: Text('← Voltar', style: TextStyle(color: textSub)),
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

class _OptionCard extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final bool isDark;
  final VoidCallback onTap;

  const _OptionCard({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bg = isDark ? const Color(0xFF1E293B) : const Color(0xFFF8FAFC);
    final border = isDark ? const Color(0xFF334155) : const Color(0xFFE2E8F0);
    final textPrimary = isDark ? Colors.white : const Color(0xFF0F172A);
    final textSub = isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: border),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: iconColor, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(color: textSub, fontSize: 12),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: textSub, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

/// Máscara cinza translúcida que escurece a imagem da câmera ao redor da área de leitura
class _ScannerCutoutPainter extends CustomPainter {
  final Rect scanWindow;
  final double borderRadius;
  final Color overlayColor;

  const _ScannerCutoutPainter({
    required this.scanWindow,
    required this.borderRadius,
    this.overlayColor = const Color(0xB81E293B),
  });

  @override
  void paint(Canvas canvas, Size size) {
    final backgroundPath = Path()
      ..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final cutoutPath = Path()
      ..addRRect(RRect.fromRectAndRadius(scanWindow, Radius.circular(borderRadius)));

    // Subtrai o retângulo de leitura do fundo para deixar o centro transparente e as bordas cinzas
    final overlayPath = Path.combine(PathOperation.difference, backgroundPath, cutoutPath);
    final paint = Paint()
      ..color = overlayColor
      ..style = PaintingStyle.fill;

    canvas.drawPath(overlayPath, paint);
  }

  @override
  bool shouldRepaint(covariant _ScannerCutoutPainter oldDelegate) {
    return oldDelegate.scanWindow != scanWindow ||
        oldDelegate.borderRadius != borderRadius ||
        oldDelegate.overlayColor != overlayColor;
  }
}
