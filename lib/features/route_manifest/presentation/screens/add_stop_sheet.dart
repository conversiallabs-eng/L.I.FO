import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import '../../../../core/services/geocoding_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../route_manifest/data/manifest_repository.dart';
import '../manifest_controller.dart';

class _PackageRow {
  final TextEditingController barcode = TextEditingController();
  final TextEditingController description = TextEditingController();
  final TextEditingController weight = TextEditingController();

  void dispose() {
    barcode.dispose();
    description.dispose();
    weight.dispose();
  }
}

/// Sheet de cadastro real de parada: destinatário + endereço com busca
/// (Nominatim/OSM, sem API key) + volumes com código, descrição e peso.
class AddStopSheet extends ConsumerStatefulWidget {
  final double? startLat;
  final double? startLng;
  /// Barcode pré-preenchido (vindo do scanner quando o código não foi encontrado)
  final String? initialBarcode;

  const AddStopSheet({super.key, this.startLat, this.startLng, this.initialBarcode});

  static Future<bool?> show(
    BuildContext context, {
    double? startLat,
    double? startLng,
    String? initialBarcode,
  }) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: AddStopSheet(
          startLat: startLat,
          startLng: startLng,
          initialBarcode: initialBarcode,
        ),
      ),
    );
  }

  @override
  ConsumerState<AddStopSheet> createState() => _AddStopSheetState();
}

class _AddStopSheetState extends ConsumerState<AddStopSheet> {
  final _geocoding = GeocodingService();
  final _recipientCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  late final List<_PackageRow> _packages;

  Timer? _debounce;
  List<GeocodingResult> _suggestions = [];
  bool _searching = false;
  GeocodingResult? _selectedPlace;
  String? _formError;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final firstRow = _PackageRow();
    if (widget.initialBarcode != null && widget.initialBarcode!.isNotEmpty) {
      firstRow.barcode.text = widget.initialBarcode!;
    }
    _packages = [firstRow];
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _recipientCtrl.dispose();
    _addressCtrl.dispose();
    for (final p in _packages) {
      p.dispose();
    }
    super.dispose();
  }

  void _onAddressChanged(String text) {
    _debounce?.cancel();
    if (_selectedPlace != null && text != _selectedPlace!.displayName) {
      setState(() => _selectedPlace = null);
    }
    if (text.trim().length < 4) {
      setState(() {
        _suggestions = [];
        _searching = false;
      });
      return;
    }
    setState(() => _searching = true);
    _debounce = Timer(const Duration(milliseconds: 600), () async {
      final results = await _geocoding.searchAddress(text);
      if (!mounted) return;
      setState(() {
        _suggestions = results;
        _searching = false;
      });
    });
  }

  Future<void> _save() async {
    final recipient = _recipientCtrl.text.trim();
    if (recipient.isEmpty) {
      setState(() => _formError = 'Informe o destinatário.');
      return;
    }
    if (_selectedPlace == null) {
      setState(() => _formError = 'Busque e selecione o endereço na lista.');
      return;
    }

    final inputs = <NewPackageInput>[];
    for (final row in _packages) {
      final barcode = row.barcode.text.trim();
      if (barcode.isEmpty) continue;
      final weight = double.tryParse(row.weight.text.trim().replaceAll(',', '.'));
      if (weight == null || weight <= 0) {
        setState(() => _formError = 'Peso inválido no volume $barcode (ex: 12,5).');
        return;
      }
      inputs.add(NewPackageInput(
        barcode: barcode,
        description: row.description.text.trim().isEmpty
            ? 'Volume $barcode'
            : row.description.text.trim(),
        weightKg: weight,
      ));
    }
    if (inputs.isEmpty) {
      setState(() => _formError = 'Adicione ao menos um volume com código.');
      return;
    }

    setState(() {
      _formError = null;
      _saving = true;
    });

    // Ordem parte do ponto real: fix fresco do GPS no momento de salvar.
    double? startLat = widget.startLat;
    double? startLng = widget.startLng;
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );
      startLat = pos.latitude;
      startLng = pos.longitude;
    } catch (_) {}

    final ok = await ref.read(manifestControllerProvider.notifier).addStop(
          recipientName: recipient,
          address: _selectedPlace!.displayName,
          latitude: _selectedPlace!.latitude,
          longitude: _selectedPlace!.longitude,
          packages: inputs,
          startLat: startLat,
          startLng: startLng,
        );

    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() => _saving = false);
      final msg = ref.read(manifestControllerProvider).errorMessage;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg ?? 'Falha ao salvar parada.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final subColor = isDark ? AppColors.textSlate : AppColors.lightTextSecondary;

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 38,
                height: 4.5,
                decoration: BoxDecoration(
                  color: isDark ? AppColors.carbonBorder : AppColors.lightBorder,
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
            const SizedBox(height: 14),
            const Text(
              'Nova Parada',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 4),
            Text(
              'Endereço real com busca — o app calcula rota e LIFO.',
              style: TextStyle(fontSize: 12, color: subColor),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _recipientCtrl,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Destinatário',
                hintText: 'Ex: Mercado Central - Galpão 4',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _addressCtrl,
              onChanged: _onAddressChanged,
              decoration: InputDecoration(
                labelText: 'Endereço',
                hintText: 'Rua, número, cidade...',
                border: const OutlineInputBorder(),
                suffixIcon: _searching
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : (_selectedPlace != null
                        ? const Icon(Icons.check_circle, color: AppColors.statusSuccess)
                        : null),
              ),
            ),
            if (_suggestions.isNotEmpty && _selectedPlace == null) ...[
              const SizedBox(height: 8),
              Container(
                decoration: BoxDecoration(
                  border: Border.all(
                    color: isDark ? AppColors.carbonBorder : AppColors.lightBorder,
                  ),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (int i = 0; i < _suggestions.length; i++) ...[
                      if (i > 0) const Divider(height: 1),
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.place_outlined, size: 20),
                        title: Text(
                          _suggestions[i].displayName,
                          style: const TextStyle(fontSize: 12),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onTap: () {
                          setState(() {
                            _selectedPlace = _suggestions[i];
                            _addressCtrl.text = _suggestions[i].displayName;
                            _suggestions = [];
                          });
                        },
                      ),
                    ],
                  ],
                ),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                const Text(
                  'VOLUMES',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, letterSpacing: 0.8),
                ),
                const Spacer(),
                Text(
                  '${_packages.length} ${_packages.length == 1 ? 'item' : 'itens'}',
                  style: TextStyle(fontSize: 12, color: subColor),
                ),
              ],
            ),
            const SizedBox(height: 8),
            for (int i = 0; i < _packages.length; i++)
              _buildPackageRow(i, isDark),
            OutlinedButton.icon(
              onPressed: () => setState(() => _packages.add(_PackageRow())),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Adicionar volume'),
            ),
            if (_formError != null) ...[
              const SizedBox(height: 8),
              Text(
                _formError!,
                style: const TextStyle(color: AppColors.statusDanger, fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ],
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.save_outlined, size: 18),
              label: Text(_saving ? 'Salvando...' : 'Salvar parada'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPackageRow(int index, bool isDark) {
    final row = _packages[index];
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(
          color: isDark ? AppColors.carbonBorder : AppColors.lightBorder,
        ),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Text(
                'Volume ${index + 1}',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              if (_packages.length > 1)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Remover volume',
                  icon: const Icon(Icons.delete_outline, size: 18),
                  onPressed: () => setState(() {
                    row.dispose();
                    _packages.removeAt(index);
                  }),
                ),
            ],
          ),
          TextField(
            controller: row.barcode,
            textCapitalization: TextCapitalization.characters,
            decoration: const InputDecoration(
              labelText: 'Código',
              hintText: 'Ex: LF-882190',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: row.description,
                  decoration: const InputDecoration(
                    labelText: 'Descrição',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                flex: 2,
                child: TextField(
                  controller: row.weight,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Peso (kg)',
                    hintText: '12,5',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
