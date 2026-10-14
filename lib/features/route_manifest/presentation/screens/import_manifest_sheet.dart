import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import '../../../../core/services/geocoding_service.dart';
import '../../../../core/services/manifest_import_service.dart';
import '../../../../core/utils/lifo_calculator.dart';
import '../../../../core/theme/app_colors.dart';
import '../manifest_controller.dart';

enum _GeoStatus { pending, locating, ok, fail }

class _PreviewStop {
  final ImportedStop imported;
  _GeoStatus status;
  double? lat;
  double? lng;
  bool fromFile;

  _PreviewStop(this.imported)
      : status = _GeoStatus.pending,
        fromFile = false;
}

/// Importação de manifesto: seleciona um arquivo do armazenamento
/// (CSV, TXT, XLS, XLSX), localiza os endereços e gera o manifesto
/// com rota + LIFO calculados.
class ImportManifestSheet extends ConsumerStatefulWidget {
  final double? startLat;
  final double? startLng;

  const ImportManifestSheet({super.key, this.startLat, this.startLng});

  /// Retorna os metros do trajeto ORIGINAL (ordem do arquivo, a partir do
  /// GPS) quando a importação conclui — null se cancelada ou com falha.
  /// O chamador usa para o comparativo "você economizou X km".
  static Future<double?> show(
    BuildContext context, {
    double? startLat,
    double? startLng,
  }) {
    return showModalBottomSheet<double>(
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
        child: ImportManifestSheet(startLat: startLat, startLng: startLng),
      ),
    );
  }

  @override
  ConsumerState<ImportManifestSheet> createState() =>
      _ImportManifestSheetState();
}

class _ImportManifestSheetState extends ConsumerState<ImportManifestSheet> {
  final _importer = ManifestImportService();
  final _geocoding = GeocodingService();

  String? _fileName;
  bool _parsing = false;
  String? _parseError;
  List<_PreviewStop> _stops = [];
  int _skippedCancelled = 0;
  int _rowsWithoutAddress = 0;

  bool _locating = false;
  int _located = 0;
  int _toLocate = 0;
  String? _lastFound;
  bool _cancelRequested = false;
  bool _confirming = false;
  String? _confirmStatusText;

  int get _okCount => _stops.where((s) => s.status == _GeoStatus.ok).length;
  int get _totalUnits => _stops.fold(0, (a, s) => a + s.imported.totalUnits);

  @override
  void dispose() {
    _cancelRequested = true;
    super.dispose();
  }

  Future<void> _pickFile() async {
    setState(() {
      _parseError = null;
      _parsing = true;
    });
    try {
      late final String fileName;
      late final List<int> bytes;
      try {
        final files = await FilePicker.pickFiles(
          type: FileType.custom,
          allowedExtensions: ['csv', 'txt', 'xls', 'xlsx'],
        );
        if (files.isEmpty) {
          setState(() => _parsing = false);
          return;
        }
        final file = files.first;
        fileName = file.name;
        bytes = await file.readAsBytes();
      } catch (e) {
        debugPrint('LIFO import pick/read falhou: $e');
        final msg = e.toString().contains('MissingPluginException')
            ? 'Feche e abra o app de novo para concluir a atualização e tente outra vez.'
            : 'Não consegui abrir esse arquivo. Tente outro arquivo.';
        throw ImportException(msg);
      }
      if (bytes.isEmpty) {
        throw const ImportException('Arquivo vazio.');
      }
      final rows = await _importer.readRows(fileName, bytes);
      final parsed = ManifestImportService.parseRows(rows);
      if (!mounted) return;
      final previews = parsed.stops.map(_PreviewStop.new).toList();
      int preLocated = 0;
      // Coordenada do próprio arquivo: ok instantâneo, sem rede.
      for (final p in previews) {
        if (p.imported.hasCoords) {
          p.status = _GeoStatus.ok;
          p.lat = p.imported.latitude;
          p.lng = p.imported.longitude;
          p.fromFile = true;
          preLocated++;
        }
      }
      setState(() {
        _fileName = fileName;
        _stops = previews;
        _skippedCancelled = parsed.skippedCancelled;
        _rowsWithoutAddress = parsed.rowsWithoutAddress;
        _parsing = false;
        _toLocate = previews.length;
        _located = preLocated;
      });
      if (parsed.stops.isEmpty && mounted) {
        setState(() => _parseError =
            'Nenhum pedido aproveitável nesse arquivo. Confira se tem colunas de pedido, destinatário e endereço.');
        return;
      }
      // Fluxo automático: localiza o restante sozinho e importa em seguida.
      await _locate();
      if (mounted &&
          _stops.isNotEmpty &&
          _stops.every((s) => s.status == _GeoStatus.ok)) {
        await _confirm();
      }
    } on ImportException catch (e) {
      if (mounted) {
        setState(() {
          _parseError = e.message;
          _parsing = false;
        });
      }
    } catch (e) {
      debugPrint('LIFO import parse falhou: $e');
      if (mounted) {
        setState(() {
          _parseError = 'Falha ao ler o arquivo. Tente outro formato.';
          _parsing = false;
        });
      }
    }
  }

  Future<void> _locate({bool onlyFailed = false}) async {
    if (_locating) return;
    final targets = <int>[];
    for (int i = 0; i < _stops.length; i++) {
      final s = _stops[i];
      if (onlyFailed ? s.status == _GeoStatus.fail : s.status != _GeoStatus.ok) {
        targets.add(i);
      }
    }
    if (targets.isEmpty) return;

    final int alreadyFound = _okCount;
    setState(() {
      _locating = true;
      _cancelRequested = false;
      _toLocate = _stops.length;
      _located = alreadyFound;
      _lastFound = null;
      for (final i in targets) {
        _stops[i].status = _GeoStatus.locating;
      }
    });

    final queries = [for (final i in targets) _stops[i].imported.addressQuery];
    final results = await _geocoding.geocodeBatchFast(
      queries,
      biasLat: widget.startLat,
      biasLng: widget.startLng,
      shouldCancel: () => _cancelRequested,
      onProgress: (done, total, last) {
        if (mounted) {
          setState(() {
            _located = alreadyFound + done;
            if (last != null) _lastFound = last.displayName;
          });
        }
      },
    );

    if (!mounted) return;
    final wasCancelled = _cancelRequested;
    setState(() {
      for (int k = 0; k < targets.length; k++) {
        final s = _stops[targets[k]];
        final r = k < results.length ? results[k] : null;
        if (r == null) {
          s.status = _GeoStatus.fail;
        } else {
          s.status = _GeoStatus.ok;
          s.lat = r.latitude;
          s.lng = r.longitude;
        }
      }
      _rejectOutliers();
      _locating = false;
    });
    // Conclusão automática: achou ao menos um endereço, importa direto.
    if (!wasCancelled && _okCount > 0) {
      await _confirm();
    }
  }

  /// Descarta resultados fora da região do lote (ex.: match em outro
  /// estado/país). Sem isso, um único outlier abre o enquadramento para o
  /// continente e a rota "some" do mapa.
  void _rejectOutliers() {
    final ok = _stops
        .where((s) => s.status == _GeoStatus.ok && s.lat != null && s.lng != null)
        .toList();
    if (ok.length < 3) return;

    final lats = ok.map((s) => s.lat!).toList()..sort();
    final lngs = ok.map((s) => s.lng!).toList()..sort();
    final midLat = lats[lats.length ~/ 2];
    final midLng = lngs[lngs.length ~/ 2];

    for (final s in ok) {
      final dist = LifoCalculator.calculateDistanceMeters(
        midLat, midLng, s.lat!, s.lng!,
      );
      if (dist > 120000) {
        s.status = _GeoStatus.fail;
        s.lat = null;
        s.lng = null;
      }
    }
  }

  Future<void> _confirm() async {
    if (_confirming) return;
    final resolved = <ResolvedImportStop>[];
    for (final s in _stops) {
      if (s.status == _GeoStatus.ok && s.lat != null && s.lng != null) {
        resolved.add(ManifestImportService.resolve(s.imported, s.lat!, s.lng!));
      }
    }
    if (resolved.isEmpty) return;

    setState(() {
      _confirming = true;
      _toLocate = _stops.length;
      _located = resolved.length;
      _confirmStatusText = 'Obtendo GPS e preparando rota...';
    });

    // A ordem da rota parte do ponto real: tenta um fix fresco do GPS no
    // momento de confirmar (a primeira parada = a mais perto de você).
    double? startLat = widget.startLat;
    double? startLng = widget.startLng;
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 8),
        ),
      );
      startLat = pos.latitude;
      startLng = pos.longitude;
    } catch (_) {
      try {
        final last = await Geolocator.getLastKnownPosition();
        if (last != null) {
          startLat = last.latitude;
          startLng = last.longitude;
        }
      } catch (_) {}
    }
    final gpsOk = startLat != null && startLng != null;

    if (mounted) {
      setState(() {
        _confirmStatusText = 'Otimizando trajeto pelas ruas (OSRM)...';
      });
    }

    String cleanFormatName = 'Manifesto';
    if (_fileName != null && _fileName!.trim().isNotEmpty) {
      cleanFormatName = _fileName!.replaceAll(RegExp(r'\.[a-zA-Z0-9]+$'), '').trim();
    }
    if (cleanFormatName.isEmpty) cleanFormatName = 'Manifesto';

    // Km do trajeto ORIGINAL: ordem do arquivo, partindo do mesmo GPS.
    // É a base honesta do comparativo "economizou X km com o LIFO".
    final originalMeters = _originalPathMeters(resolved, startLat, startLng);

    final ok = await ref.read(manifestControllerProvider.notifier).importManifest(
          formatName: cleanFormatName,
          stops: resolved,
          startLat: startLat,
          startLng: startLng,
        );
    if (!mounted) return;
    if (ok) {
      final ignored = _stops.length - resolved.length;
      if (!gpsOk && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Sem sinal de GPS: ordem calculada sem ponto de partida.',
            ),
          ),
        );
      }
      if (ignored > 0 && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${resolved.length} paradas na rota • $ignored fora da rota (endereço não localizado)',
            ),
          ),
        );
      }
      Navigator.of(context).pop(originalMeters);
    } else {
      setState(() => _confirming = false);
      final msg = ref.read(manifestControllerProvider).errorMessage;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg ?? 'Falha ao importar manifesto.')),
      );
    }
  }

  /// Soma Haversine na ordem de chegada do arquivo (ponto de partida = GPS).
  static double _originalPathMeters(
    List<ResolvedImportStop> stops,
    double? startLat,
    double? startLng,
  ) {
    if (stops.isEmpty) return 0;
    double total = 0;
    double prevLat = startLat ?? stops.first.latitude;
    double prevLng = startLng ?? stops.first.longitude;
    final start = (startLat != null && startLng != null) ? 0 : 1;
    for (int i = start; i < stops.length; i++) {
      total += LifoCalculator.calculateDistanceMeters(
        prevLat,
        prevLng,
        stops[i].latitude,
        stops[i].longitude,
      );
      prevLat = stops[i].latitude;
      prevLng = stops[i].longitude;
    }
    return total;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final subColor = isDark ? AppColors.textSlate : AppColors.lightTextSecondary;

    return PopScope(
      // Não deixa dispensar no meio da localização/importação (evita
      // fechar sem querer e achar que "não importou").
      canPop: !_locating && !_confirming,
      child: SafeArea(
        child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.92,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
            Container(
              width: 38,
              height: 4.5,
              decoration: BoxDecoration(
                color: isDark ? AppColors.carbonBorder : AppColors.lightBorder,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Row(
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Importar Manifesto',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'Arquivo do armazenamento vira rota + LIFO.',
                          style: TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Fechar',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 320),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 0.06),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                ),
                child: KeyedSubtree(
                  key: ValueKey(_stops.isEmpty ? 'file' : 'preview'),
                  child: _stops.isEmpty
                      ? _buildFileStep(subColor)
                      : _buildPreviewStep(subColor, isDark),
                ),
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }

  Widget _buildFileStep(Color subColor) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ElevatedButton.icon(
            onPressed: _parsing ? null : _pickFile,
            icon: _parsing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                  )
                : const Icon(Icons.upload_file_outlined, size: 18),
            label: Text(_parsing ? 'Lendo arquivo...' : 'Selecionar arquivo'),
          ),
          if (_parseError != null) ...[
            const SizedBox(height: 10),
            Text(
              _parseError!,
              style: const TextStyle(
                color: AppColors.statusDanger,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          const SizedBox(height: 16),
          Text(
            'Os endereços são localizados online — 1 por segundo. Pedidos sem endereço aproveitável ficam de fora da contagem.',
            style: TextStyle(fontSize: 11, color: subColor),
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewStep(Color subColor, bool isDark) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _fileName ?? '',
                      style: TextStyle(fontSize: 12, color: subColor),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _parsing ? null : _pickFile,
                    icon: const Icon(Icons.swap_horiz, size: 16),
                    label: const Text('Trocar', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '${_stops.length} pedidos • $_totalUnits vol • $_okCount endereços ok'
                '${_skippedCancelled > 0 ? ' • $_skippedCancelled cancelados fora' : ''}'
                '${_rowsWithoutAddress > 0 ? ' • $_rowsWithoutAddress sem endereço fora' : ''}',
                style: TextStyle(fontSize: 12, color: subColor, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              if (_locating || _confirming)
                _buildLoader(subColor, isDark)
              else if (_okCount == 0)
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _locate(),
                        icon: const Icon(Icons.refresh_outlined, size: 16),
                        label: const Text(
                          'Tentar localizar de novo',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                  ],
                )
              else if (_cancelRequested)
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _confirm,
                        icon: const Icon(Icons.check_circle_outline, size: 16),
                        label: Text(
                          'Concluir importação ($_okCount)',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),
        if (!_locating && !_confirming) ...[
          const Divider(height: 1),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              itemCount: _stops.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, i) => _FadeSlideIn(
                delayMs: (i * 35).clamp(0, 500),
                child: _buildStopRow(i, subColor, isDark),
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// Loader Circuit: anel de progresso com glow, ticker do último endereço
  /// e zero lista — fluido mesmo com 100+ paradas.
  Widget _buildLoader(Color subColor, bool isDark) {
    final int total = _toLocate > 0 ? _toLocate : (_stops.isNotEmpty ? _stops.length : 1);
    final int current = _confirming ? (_okCount > 0 ? _okCount : _located) : _located;
    final double progress = (total > 0 ? current / total : 0.0).clamp(0.0, 1.0);
    final pct = (progress * 100).round();

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 132,
            height: 132,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: AppColors.circuitBlue.withValues(alpha: 0.45),
                  blurRadius: 32,
                  spreadRadius: 4,
                ),
              ],
            ),
            child: Stack(
              alignment: Alignment.center,
              children: [
                SizedBox(
                  width: 132,
                  height: 132,
                  child: CircularProgressIndicator(
                    value: _confirming ? null : (progress > 0 ? progress : null),
                    strokeWidth: 10,
                    backgroundColor:
                        isDark ? AppColors.carbonBorder : AppColors.lightBorder,
                    valueColor: const AlwaysStoppedAnimation<Color>(
                      AppColors.circuitBlueGlow,
                    ),
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _confirming ? '$current' : '$pct%',
                      style: const TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    Text(
                      '$current/$total paradas',
                      style: TextStyle(
                        fontSize: 11,
                        color: subColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            switchInCurve: Curves.easeOutCubic,
            child: Text(
              _confirming
                  ? (_confirmStatusText ?? 'Otimizando sua rota viária...')
                  : 'Localizando endereços ($current/$total)...',
              key: ValueKey(_confirming
                  ? (_confirmStatusText ?? 'opt')
                  : 'loc-$current'),
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 6),
          if (_lastFound != null && !_confirming)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.check_circle,
                  color: AppColors.statusSuccess,
                  size: 14,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    _lastFound!,
                    style: TextStyle(fontSize: 12, color: subColor),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            )
          else
            Text(
              _confirming
                  ? 'Traçando melhor caminho na malha viária real'
                  : 'Busca ultrarrápida — sem tocar em nada',
              style: TextStyle(fontSize: 12, color: subColor),
            ),
          if (_locating) ...[
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => setState(() => _cancelRequested = true),
              child: const Text('Parar', style: TextStyle(fontSize: 12)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStopRow(int index, Color subColor, bool isDark) {
    final s = _stops[index];
    final border = isDark ? AppColors.carbonBorder : AppColors.lightBorder;

    Icon statusIcon;
    switch (s.status) {
      case _GeoStatus.ok:
        statusIcon = const Icon(Icons.check_circle, color: AppColors.statusSuccess, size: 20);
        break;
      case _GeoStatus.fail:
        statusIcon = const Icon(Icons.error_outline, color: AppColors.statusDanger, size: 20);
        break;
      case _GeoStatus.locating:
        statusIcon = const Icon(Icons.hourglass_empty, color: AppColors.accentAmber, size: 20);
        break;
      case _GeoStatus.pending:
        statusIcon = Icon(Icons.radio_button_unchecked, color: subColor, size: 20);
        break;
    }

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          statusIcon,
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  s.imported.recipient,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  s.imported.displayAddress,
                  style: TextStyle(fontSize: 11, color: subColor),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  '${s.imported.orderRef} • ${s.imported.totalUnits} vol'
                  '${s.fromFile ? ' • coord. arquivo' : ''}',
                  style: TextStyle(fontSize: 11, color: subColor, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Remover pedido',
            icon: const Icon(Icons.delete_outline, size: 18),
            onPressed: _locating ? null : () => setState(() => _stops.removeAt(index)),
          ),
        ],
      ),
    );
  }
}

/// Entrada escalonada de cada linha da lista (fade + subida leve).
/// Disparo único com atraso por índice — barato mesmo com 100+ pedidos.
class _FadeSlideIn extends StatefulWidget {
  final int delayMs;
  final Widget child;

  const _FadeSlideIn({required this.delayMs, required this.child});

  @override
  State<_FadeSlideIn> createState() => _FadeSlideInState();
}

class _FadeSlideInState extends State<_FadeSlideIn> {
  Timer? _timer;
  bool _shown = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(Duration(milliseconds: widget.delayMs), () {
      if (mounted) setState(() => _shown = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: _shown ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
      child: AnimatedSlide(
        offset: _shown ? Offset.zero : const Offset(0, 0.18),
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
        child: widget.child,
      ),
    );
  }
}
