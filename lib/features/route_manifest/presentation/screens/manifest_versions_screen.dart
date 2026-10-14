import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../../core/theme/app_colors.dart';
import '../manifest_controller.dart';
import '../../domain/models/manifest_version.dart';

class ManifestVersionsScreen extends ConsumerWidget {
  const ManifestVersionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manifestState = ref.watch(manifestControllerProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final history = manifestState.versionHistory;
    final current = manifestState.currentVersion;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Auditoria e Historico de Rotas'),
        actions: [
          IconButton(
            tooltip: 'Atualizar Lista',
            icon: const Icon(Icons.refresh),
            onPressed: () {
              ref.read(manifestControllerProvider.notifier).init();
            },
          ),
        ],
      ),
      body: manifestState.isLoading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Action header card
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: isDark ? AppColors.darkBorder : AppColors.lightBorder,
                        width: 1.5,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'SISTEMA DE VERSIONAMENTO IMUTAVEL',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.0,
                            color: AppColors.primaryBlueLight,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Cada calculo gera um snapshot estrito. O Manifesto Original (v0) permanece inalterado para auditoria.',
                          style: TextStyle(
                            fontSize: 13,
                            color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
                          ),
                        ),
                        const SizedBox(height: 14),
                        ElevatedButton.icon(
                          onPressed: () {
                            ref.read(manifestControllerProvider.notifier).reoptimizeRoute();
                          },
                          icon: const Icon(Icons.alt_route_outlined),
                          label: const Text('Calcular Nova Re-otimizacao'),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 20),

                  Row(
                    children: [
                      const Text(
                        'ARVORE DE VERSOES',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.8,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '${history.length} snapshots registrados',
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark ? AppColors.darkTextMuted : AppColors.lightTextMuted,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),

                  Expanded(
                    child: history.isEmpty
                        ? Center(
                            child: Text(
                              'Nenhum historico de manifesto registrado.',
                              style: TextStyle(
                                color: isDark ? AppColors.darkTextMuted : AppColors.lightTextMuted,
                              ),
                            ),
                          )
                        : ListView.separated(
                            itemCount: history.length,
                            separatorBuilder: (context, index) => const SizedBox(height: 12),
                            itemBuilder: (context, index) {
                              final item = history[index];
                              final isCurrentActive = current?.id == item.id;
                              return _buildVersionCard(
                                context: context,
                                ref: ref,
                                version: item,
                                isCurrentActive: isCurrentActive,
                                isDark: isDark,
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildVersionCard({
    required BuildContext context,
    required WidgetRef ref,
    required ManifestVersion version,
    required bool isCurrentActive,
    required bool isDark,
  }) {
    final dateFormat = DateFormat('dd/MM/yyyy HH:mm:ss');
    final formattedDate = dateFormat.format(version.createdAt);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isCurrentActive
              ? AppColors.statusSuccess
              : (isDark ? AppColors.darkBorder : AppColors.lightBorder),
          width: isCurrentActive ? 2 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: version.versionIndex == 0
                      ? AppColors.accentAmber.withValues(alpha: 0.15)
                      : AppColors.primaryBlueLight.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'v${version.versionIndex}',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: version.versionIndex == 0 ? AppColors.accentAmber : AppColors.primaryBlueLight,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  version.label,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              if (isCurrentActive)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.statusSuccess,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: const Text(
                    'ATIVO',
                    style: TextStyle(
                      color: Colors.black,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Criado em: $formattedDate',
            style: TextStyle(
              fontSize: 12,
              color: isDark ? AppColors.darkTextSecondary : AppColors.lightTextSecondary,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Text(
                '${version.totalStops} paradas • ${version.totalPackages} volumes',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
                ),
              ),
              if (version.parentVersionId != null) ...[
                const SizedBox(width: 8),
                Text(
                  '• Derivado da versao anterior',
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark ? AppColors.darkTextMuted : AppColors.lightTextMuted,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          const Divider(height: 1),
          const SizedBox(height: 10),
          Row(
            children: [
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
                onPressed: () {
                  _showRawSnapshotDialog(context, version, isDark);
                },
                icon: const Icon(Icons.code, size: 16),
                label: const Text('Inspecionar Snapshot', style: TextStyle(fontSize: 12)),
              ),
              const Spacer(),
              if (!isCurrentActive)
                ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: isDark ? AppColors.darkSurfaceElevated : AppColors.lightSurfaceElevated,
                    foregroundColor: isDark ? AppColors.darkTextPrimary : AppColors.lightTextPrimary,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  ),
                  onPressed: () {
                    _confirmReversion(context, ref, version);
                  },
                  icon: const Icon(Icons.history, size: 16),
                  label: const Text('Reverter Rota', style: TextStyle(fontSize: 12)),
                ),
            ],
          ),
        ],
      ),
    );
  }

  void _confirmReversion(BuildContext context, WidgetRef ref, ManifestVersion version) {
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Confirmar Reversao de Rota'),
          content: Text(
            'Deseja restaurar a "${version.label}"? O historico completo continuara preservado no banco de dados local.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancelar'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                ref.read(manifestControllerProvider.notifier).revertToVersion(version.id);
              },
              child: const Text('Confirmar Reversao'),
            ),
          ],
        );
      },
    );
  }

  void _showRawSnapshotDialog(BuildContext context, ManifestVersion version, bool isDark) {
    String prettyJson = version.rawData;
    try {
      final decoded = jsonDecode(version.rawData);
      prettyJson = const JsonEncoder.withIndent('  ').convert(decoded);
    } catch (_) {}

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: isDark ? AppColors.darkSurface : AppColors.lightSurface,
          title: Text('Snapshot Bruto: ${version.label}'),
          content: SizedBox(
            width: double.maxFinite,
            height: 380,
            child: SingleChildScrollView(
              child: SelectableText(
                prettyJson,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Fechar'),
            ),
          ],
        );
      },
    );
  }
}
