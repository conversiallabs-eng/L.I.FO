import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import '../../../../core/database/app_database.dart';
import '../../../../core/services/offline_map_service.dart';
import '../../../../core/map/tile_cache.dart';

/// Tela "Mapas offline": baixa a cidade atual ou busca por nome.
/// Cada cidade é uma região independente no SQLite (`offline_regions`).
class OfflineMapsScreen extends StatefulWidget {
  const OfflineMapsScreen({super.key});

  static void open(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const OfflineMapsScreen()),
    );
  }

  @override
  State<OfflineMapsScreen> createState() => _OfflineMapsScreenState();
}

class _OfflineMapsScreenState extends State<OfflineMapsScreen> {
  final _searchCtrl = TextEditingController();
  List<OfflineRegion> _regions = [];
  int? _cacheBytes;
  bool _loading = true;
  bool _busy = false;
  String? _status;
  double _progress = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      final regions = await OfflineMapService.instance.listRegions();
      final bytes = await TileCache.instance.cacheSizeBytes();
      if (!mounted) return;
      setState(() {
        _regions = regions;
        _cacheBytes = bytes;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  String _fmtBytes(int? bytes) {
    if (bytes == null || bytes < 0) return '—';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(0)} MB';
  }

  Future<void> _downloadCurrentCity() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = 'Obtendo GPS…';
      _progress = 0;
    });
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 6),
        ),
      );
      if (!mounted) return;
      setState(() => _status = 'Descobrindo cidade…');
      final city = await OfflineMapService.instance
          .reverseGeocodeCity(pos.latitude, pos.longitude);
      final query = city ?? '${pos.latitude},${pos.longitude}';
      // Libera o flag interno para o segundo passo reutilizar o fluxo.
      setState(() => _busy = false);
      await _downloadQuery(query);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = 'GPS indisponível. Busque a cidade pelo nome abaixo.';
      });
    }
  }

  Future<void> _downloadQuery(String query) async {
    if (_busy) return;
    final q0 = query.trim();
    if (q0.length < 3) {
      setState(() => _status = 'Digite ao menos 3 letras. Ex.: São José, SC');
      return;
    }
    setState(() {
      _busy = true;
      _status = 'Buscando "$q0"…';
      _progress = 0;
    });
    try {
      var q = q0;
      if (!q.contains(',') && !q.contains(' ')) q = '$q, Brasil';
      final bbox =
          await OfflineMapService.instance.fetchCityBoundingBox(q);
      if (bbox == null) {
        if (!mounted) return;
        setState(() {
          _busy = false;
          _status = 'Cidade não encontrada. Tente "Florianópolis, SC".';
        });
        return;
      }
      final svc = OfflineMapService.instance;
      final key = svc.normalizeCityKey(q.split(',').first);
      if (!mounted) return;
      setState(
          () => _status = 'Baixando ${bbox.displayName.split(',').first}…');
      await svc.downloadRegion(
        cityKey: key,
        displayName: bbox.displayName.split(',').take(2).join(','),
        minLat: bbox.minLat,
        maxLat: bbox.maxLat,
        minLng: bbox.minLng,
        maxLng: bbox.maxLng,
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() {
            _progress = total <= 0 ? 0 : done / total;
            _status = 'Baixando… $done/$total';
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = 'Pronto! A cidade abre sem internet.';
        _progress = 1;
      });
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status =
            'Falha: ${e.toString().replaceFirst('StateError: ', '').split('\n').first}';
      });
    }
  }

  Future<void> _delete(OfflineRegion r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Apagar mapa offline?'),
        content: Text(
          'Deseja remover "${r.displayName}" da lista de regiões offline salvas?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Remover'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await AppDatabase.instance.deleteOfflineRegion(r.cityKey);
      await _refresh();
    } catch (_) {}
  }

  Future<void> _confirmClearCache() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Limpar cache de mapas?'),
        content: const Text(
          'Isso liberará o espaço em disco ocupado pelos blocos de mapa baixados. '
          'Você poderá baixar suas cidades novamente a qualquer momento.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancelar'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Limpar'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await TileCache.instance.clearAllCache();
      await _refresh();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(title: const Text('Mapas offline')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Cache em disco: ${_fmtBytes(_cacheBytes)}',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w600,
                                        color: isDark
                                            ? const Color(0xFFE2E8F0)
                                            : const Color(0xFF1E293B),
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      'Mapas permanentes (sem expiração)',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: isDark
                                            ? const Color(0xFF94A3B8)
                                            : const Color(0xFF64748B),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if ((_cacheBytes ?? 0) > 0)
                                TextButton.icon(
                                  onPressed: _busy ? null : _confirmClearCache,
                                  icon: const Icon(Icons.cleaning_services, size: 16),
                                  label: const Text('Limpar', style: TextStyle(fontSize: 12)),
                                ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          ElevatedButton.icon(
                            onPressed: _busy ? null : _downloadCurrentCity,
                            icon: const Icon(Icons.my_location),
                            label:
                                const Text('Baixar minha cidade (GPS)'),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _searchCtrl,
                                  decoration: const InputDecoration(
                                    hintText: 'Ex.: São José, SC',
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                  onSubmitted: (v) => _downloadQuery(v),
                                ),
                              ),
                              const SizedBox(width: 8),
                              IconButton.filled(
                                onPressed: _busy
                                    ? null
                                    : () =>
                                        _downloadQuery(_searchCtrl.text),
                                icon: const Icon(Icons.download),
                                tooltip: 'Baixar cidade',
                              ),
                            ],
                          ),
                          if (_status != null) ...[
                            const SizedBox(height: 12),
                            if (_busy)
                              LinearProgressIndicator(value: _progress),
                            const SizedBox(height: 6),
                            Text(_status!),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Cidades baixadas (${_regions.length})',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  if (_regions.isEmpty)
                    const Card(
                      child: Padding(
                        padding: EdgeInsets.all(16),
                        child: Text(
                          'Nenhuma cidade ainda. Baixe a sua cidade acima — '
                          'a rota também baixa o entorno sozinha quando há internet.',
                        ),
                      ),
                    )
                  else
                    for (final r in _regions)
                      Card(
                        child: ListTile(
                          leading: Icon(
                            r.status == 'complete'
                                ? Icons.check_circle
                                : Icons.cloud_download,
                            color: r.status == 'complete'
                                ? Colors.green
                                : Colors.orange,
                          ),
                          title: Text(r.displayName),
                          subtitle: Text(
                            '${(r.progress * 100).toStringAsFixed(0)}% • '
                            '${r.tilesDone}/${r.tilesTotal} tiles • ${r.status}',
                          ),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => _delete(r),
                          ),
                        ),
                      ),
                ],
              ),
            ),
    );
  }
}
