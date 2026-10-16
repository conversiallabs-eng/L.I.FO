import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../network/supabase_service.dart';

/// Versão publicada do APK — uma linha do `app_config` no Supabase.
///
/// Quem manda é o servidor: o APK novo sobe para a Hostinger (lifo.com.br) e
/// a versão entra no `app_config` pelo script `supabase/release_apk.sql`.
/// O app compara com a versão instalada e só então oferece o download.
@immutable
class AppRelease {
  const AppRelease({
    required this.version,
    required this.build,
    required this.apkUrl,
    this.notes = '',
  });

  /// versionName do APK publicado (ex.: "1.0.1").
  final String version;

  /// versionCode do APK publicado (o `+N` do pubspec).
  final int build;

  /// Onde o APK está hospedado.
  final String apkUrl;

  /// Novidades mostradas no diálogo (opcional).
  final String notes;

  Map<String, dynamic> toJson() => {
        'version': version,
        'build': build,
        'apk_url': apkUrl,
        'notes': notes,
      };

  /// Nulo quando o registro está incompleto (sem versão/URL não há update).
  static AppRelease? fromJson(Map<String, dynamic> json) {
    final version = (json['version'] as String? ?? '').trim();
    final apkUrl = (json['apk_url'] as String? ?? '').trim();
    if (version.isEmpty || apkUrl.isEmpty) return null;
    return AppRelease(
      version: version,
      build: json['build'] is int
          ? json['build'] as int
          : int.tryParse('${json['build']}') ?? 0,
      apkUrl: apkUrl,
      notes: (json['notes'] as String? ?? '').trim(),
    );
  }

  @override
  String toString() => 'AppRelease($version+$build, $apkUrl)';
}

/// Resultado de uma checagem de versão.
enum UpdateCheck {
  /// Tem versão publicada diferente da instalada.
  available,

  /// O servidor respondeu e a publicada é a MESMA que está instalada.
  upToDate,

  /// O servidor respondeu, mas não há release publicado no `app_config`
  /// (o `supabase/release_apk.sql` ainda não rodou). Não é erro de rede —
  /// é ausência de publicação, e a mensagem tem que dizer isso.
  nothingPublished,

  /// Não deu para falar com o servidor (offline/timeout).
  offline,
}

/// Desfecho de uma tentativa de download+instalação.
enum InstallOutcome {
  /// Não há versão mais nova — nada a fazer.
  noUpdate,

  /// O Android ainda não autorizou instalar de fontes desconhecidas.
  /// A tela de permissão do sistema foi aberta; o usuário decide e volta.
  needsPermission,

  /// Download/instalação falhou (rede, arquivo truncado, sem app instalador).
  failed,

  /// O pacote foi baixado e o instalador do Android foi aberto.
  installerOpened,
}

/// Verifica, baixa e instala a versão nova do app — apenas se a publicada no
/// servidor for superior à instalada (nunca rebaixa, nunca reinstala igual).
///
/// Canal nativo `com.lifo.app/installer` (Android): o APK baixado é entregue
/// ao sistema via FileProvider, então o app precisa da permissão
/// REQUEST_INSTALL_PACKAGES + autorização do usuário para "fontes
/// desconhecidas".
class AppUpdateService {
  static final AppUpdateService instance = AppUpdateService._internal();
  AppUpdateService._internal();

  static const MethodChannel _installer =
      MethodChannel('com.lifo.app/installer');

  static const String _kReleaseCacheKey = 'lifo_app_release_v1';

  /// Chaves do `app_config` que descrevem o release publicado. Quem escreve
  /// nelas é o `supabase/release_apk.sql` — renomear aqui exige renomear lá,
  /// senão o app nunca vê versão nova (teste de regressão cobre isso).
  static const List<String> configKeys = [
    'latest_version',
    'latest_build',
    'apk_url',
    'release_notes',
  ];

  /// Release mais nova que a instalada. `null` = app em dia (bolhinha some).
  final ValueNotifier<AppRelease?> availableUpdate =
      ValueNotifier<AppRelease?>(null);

  /// Versão instalada no aparelho (ex.: "1.0.0 (1)"). Preenchida no 1º check.
  final ValueNotifier<String> installedLabel = ValueNotifier<String>('');

  String _installedVersion = '';
  int _installedBuild = 0;

  String get installedVersion => _installedVersion;
  int get installedBuild => _installedBuild;

  /// Compara duas versões "1.2.3" campo a campo. Positivo = [a] é maior.
  /// Campo não numérico (ou ausente) conta como 0 — sem exceção.
  @visibleForTesting
  static int compareVersions(String a, String b) {
    final pa = a.split('.').map((s) => int.tryParse(s.trim()) ?? 0).toList();
    final pb = b.split('.').map((s) => int.tryParse(s.trim()) ?? 0).toList();
    final len = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < len; i++) {
      final va = i < pa.length ? pa[i] : 0;
      final vb = i < pb.length ? pb[i] : 0;
      if (va != vb) return va > vb ? 1 : -1;
    }
    return 0;
  }

  /// A publicada é DIFERENTE da instalada? É a única regra que liga a oferta
  /// de download: baixar de novo exatamente o que já está instalado não serve
  /// para nada, mas um rebuild (build novo, mesmo nome) ou um rollback têm
  /// que poder ser instalados.
  ///
  /// A comparação de nome é numérica ("1.0" == "1.0.0"), para não oferecer
  /// download por diferença de formatação — nesse caso o Android recusaria
  /// instalar o mesmo pacote.
  @visibleForTesting
  static bool differsFromInstalled({
    required String remoteVersion,
    required int remoteBuild,
    required String installedVersion,
    required int installedBuild,
  }) {
    if (compareVersions(remoteVersion, installedVersion) != 0) return true;
    return remoteBuild != installedBuild;
  }

  /// A publicada é mais ANTIGA que a instalada? Só para avisar na tela —
  /// o Android pode recusar instalar um versionCode menor.
  static bool isOlder({
    required String remoteVersion,
    required int remoteBuild,
    required String installedVersion,
    required int installedBuild,
  }) {
    final cmp = compareVersions(remoteVersion, installedVersion);
    if (cmp != 0) return cmp < 0;
    return remoteBuild < installedBuild;
  }

  /// Lê a versão instalada (PackageInfo). Feito uma vez por sessão.
  Future<void> _loadInstalled() async {
    if (_installedVersion.isNotEmpty) return;
    try {
      final info = await PackageInfo.fromPlatform()
          .timeout(const Duration(seconds: 3));
      _installedVersion = info.version.trim();
      _installedBuild = int.tryParse(info.buildNumber.trim()) ?? 0;
      installedLabel.value = '$_installedVersion ($_installedBuild)';
    } catch (_) {
      // Sem PackageInfo (canal nativo fora do ar) assume 0.0.0+0 para que o
      // pior caso seja oferecer a atualização, nunca esconder.
      if (_installedVersion.isEmpty) _installedVersion = '0.0.0';
      installedLabel.value = _installedVersion;
    }
  }

  /// Checa a versão publicada no servidor.
  Future<UpdateCheck> checkForUpdate() async {
    await _loadInstalled();
    final (remote, answered) = await _fetchRemote();
    if (!answered) {
      // Offline: vale o último release conhecido, para a bolhinha não sumir
      // de quem já sabia da atualização.
      if (availableUpdate.value == null) {
        final cached = await _readCache();
        if (cached != null) _apply(cached);
      }
      return UpdateCheck.offline;
    }
    // Servidor respondeu, mas sem release publicado: nada a oferecer.
    if (remote == null) return UpdateCheck.nothingPublished;
    await _writeCache(remote);
    return _apply(remote) ? UpdateCheck.available : UpdateCheck.upToDate;
  }

  /// Botão "Verificar atualizações": força a ida ao servidor. Mesmo contrato
  /// do [checkForUpdate].
  Future<UpdateCheck> checkNow() => checkForUpdate();

  /// Aplica a release conhecida: vira oferta só se diferir da instalada.
  bool _apply(AppRelease remote) {
    final differ = differsFromInstalled(
      remoteVersion: remote.version,
      remoteBuild: remote.build,
      installedVersion: _installedVersion,
      installedBuild: _installedBuild,
    );
    availableUpdate.value = differ ? remote : null;
    return differ;
  }

  /// Devolve (release, oServidorRespondeu).
  ///
  /// Sem release publicado as chaves simplesmente não existem no `app_config`
  /// e a consulta volta vazia — isso é "nada publicado", NÃO "sem internet"
  /// (era o que a mensagem dizia antes, mentindo para o usuário).
  Future<(AppRelease?, bool)> _fetchRemote() async {
    try {
      if (!SupabaseService.instance.isInitialized) {
        await SupabaseService.instance
            .initialize()
            .timeout(const Duration(seconds: 4));
      }
      final rows = await Supabase.instance.client
          .from('app_config')
          .select('key, value')
          .inFilter('key', configKeys)
          .timeout(const Duration(seconds: 5));
      final map = {
        for (final r in (rows as List))
          (r['key'] as String): (r['value'] as String? ?? '').trim(),
      };
      // fromJson devolve null com registro incompleto (versão/URL vazias):
      // melhor "nada publicado" do que oferecer update sem destino.
      return (
        AppRelease.fromJson({
          'version': map['latest_version'] ?? '',
          'build': int.tryParse(map['latest_build'] ?? '') ?? 0,
          'apk_url': map['apk_url'] ?? '',
          'notes': map['release_notes'] ?? '',
        }),
        true,
      );
    } catch (_) {
      return (null, false);
    }
  }

  Future<AppRelease?> _readCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kReleaseCacheKey);
      if (raw == null || raw.isEmpty) return null;
      return AppRelease.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeCache(AppRelease release) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kReleaseCacheKey, jsonEncode(release.toJson()));
    } catch (_) {}
  }

  // ─── PERMISSÃO DE FONTES DESCONHECIDAS ────────────────────────────────────

  /// O sistema autoriza instalar pacotes por este app? Sempre `true` abaixo
  /// do Android 8 (não existe a permissão) e fora do Android.
  Future<bool> canInstallPackages() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _installer.invokeMethod<bool>('canRequestPackageInstalls') ??
          true;
    } catch (_) {
      return true;
    }
  }

  /// Abre a tela do sistema "Instalar apps desconhecidos" já neste app.
  Future<bool> openInstallPermissionSettings() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _installer
              .invokeMethod<bool>('openUnknownSourcesSettings') ??
          false;
    } catch (_) {
      return false;
    }
  }

  bool _isDialogShowing = false;
  bool get isDialogShowing => _isDialogShowing;

  /// Exibe o diálogo global de notificação de atualização se não estiver aberto.
  Future<void> showUpdateDialog(
    BuildContext context,
    AppRelease release, {
    VoidCallback? onDismiss,
  }) async {
    if (_isDialogShowing) return;
    _isDialogShowing = true;

    try {
      final start = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dCtx) {
          final isDark = Theme.of(dCtx).brightness == Brightness.dark;
          final titleColor = isDark ? Colors.white : const Color(0xFF0F172A);
          final subColor =
              isDark ? const Color(0xFF94A3B8) : const Color(0xFF64748B);
          final cardBg = isDark ? const Color(0xFF1E293B) : Colors.white;

          return AlertDialog(
            backgroundColor: cardBg,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2563EB).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.system_update_rounded,
                      color: Color(0xFF2563EB), size: 24),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Nova Versão Disponível!',
                    style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                        color: titleColor),
                  ),
                ),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: isDark
                          ? const Color(0xFF0F172A)
                          : const Color(0xFFF1F5F9),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Versão Instalada:',
                              style: TextStyle(fontSize: 12, color: subColor),
                            ),
                            Text(
                              installedLabel.value.isNotEmpty
                                  ? installedLabel.value
                                  : '$_installedVersion ($_installedBuild)',
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                  color: titleColor),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              'Nova Publicada:',
                              style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFF2563EB)),
                            ),
                            Text(
                              '${release.version} (${release.build})',
                              style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF2563EB)),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (release.notes.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    Text(
                      'Novidades:',
                      style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: titleColor),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      release.notes,
                      style: TextStyle(
                          fontSize: 12.5, color: subColor, height: 1.35),
                    ),
                  ],
                  const SizedBox(height: 14),
                  Text(
                    'O download é realizado em alta velocidade e o instalador do sistema será aberto automaticamente.',
                    style: TextStyle(fontSize: 11.5, color: subColor),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Navigator.of(dCtx).pop(false);
                  onDismiss?.call();
                },
                child: Text('Mais Tarde', style: TextStyle(color: subColor)),
              ),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF2563EB),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: () => Navigator.of(dCtx).pop(true),
                icon: const Icon(Icons.download_rounded, size: 18),
                label: const Text('Baixar e Instalar'),
              ),
            ],
          );
        },
      );

      if (start == true && context.mounted) {
        await executeDownloadAndInstall(context, release);
      }
    } finally {
      _isDialogShowing = false;
    }
  }

  /// Executa o download com barra de progresso modal e abre o instalador nativo.
  Future<void> executeDownloadAndInstall(
      BuildContext context, AppRelease release) async {
    final messenger = ScaffoldMessenger.of(context);
    final progress = ValueNotifier<double>(0);

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dCtx) {
        final isDark = Theme.of(dCtx).brightness == Brightness.dark;
        return AlertDialog(
          backgroundColor: isDark ? const Color(0xFF1E293B) : Colors.white,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          content: ValueListenableBuilder<double>(
            valueListenable: progress,
            builder: (_, value, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Baixando atualização ${release.version}…',
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 13.5),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: value <= 0 ? null : value,
                    minHeight: 8,
                    backgroundColor: isDark
                        ? const Color(0xFF334155)
                        : const Color(0xFFE2E8F0),
                    valueColor: const AlwaysStoppedAnimation<Color>(
                        Color(0xFF2563EB)),
                  ),
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    '${(value * 100).clamp(0, 100).toStringAsFixed(0)}%',
                    style: const TextStyle(
                        fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    final outcome = await downloadAndInstall(
      onProgress: (p) => progress.value = p,
    );

    if (context.mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    }
    progress.dispose();

    if (!context.mounted) return;

    switch (outcome) {
      case InstallOutcome.installerOpened:
        messenger.showSnackBar(const SnackBar(
          content: Text(
              'Download concluído! Confirme a instalação na tela do Android.'),
          backgroundColor: Color(0xFF2563EB),
          behavior: SnackBarBehavior.floating,
        ));
      case InstallOutcome.needsPermission:
        messenger.showSnackBar(const SnackBar(
          content: Text(
            'Autorize "Instalar apps desconhecidos" para o Lifo e tente novamente.',
          ),
          backgroundColor: Color(0xFFD97706),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 6),
        ));
      case InstallOutcome.failed:
        messenger.showSnackBar(const SnackBar(
          content: Text(
              'Falha ao baixar atualização. Verifique a internet e tente novamente.'),
          backgroundColor: Color(0xFFDC2626),
          behavior: SnackBarBehavior.floating,
        ));
      case InstallOutcome.noUpdate:
        break;
    }
  }

  // ─── DOWNLOAD + INSTALAÇÃO ────────────────────────────────────────────────

  /// Baixa o APK publicado e abre o instalador do Android.
  ///
  /// Não roda se a versão do servidor não for mais nova que a instalada.
  Future<InstallOutcome> downloadAndInstall({
    ValueChanged<double>? onProgress,
  }) async {
    final release = availableUpdate.value;
    if (release == null) return InstallOutcome.noUpdate;

    // Fora do Android (desktop/web) não há instalador de APK: abre o link
    // para o usuário baixar na mão, em vez de falhar em silêncio.
    if (!Platform.isAndroid) {
      try {
        await launchUrl(
          Uri.parse(release.apkUrl),
          mode: LaunchMode.externalApplication,
        );
        return InstallOutcome.installerOpened;
      } catch (_) {
        return InstallOutcome.failed;
      }
    }

    if (!await canInstallPackages()) {
      // Manda o usuário para a autorização de fontes desconhecidas; ele
      // volta e toca de novo (a permissão é dele, não dá para pular).
      await openInstallPermissionSettings();
      return InstallOutcome.needsPermission;
    }

    try {
      final file = await _download(release, onProgress: onProgress);
      if (file == null) return InstallOutcome.failed;
      final ok = await _installer
          .invokeMethod<bool>('installApk', {'path': file.path});
      return (ok ?? false)
          ? InstallOutcome.installerOpened
          : InstallOutcome.failed;
    } catch (_) {
      return InstallOutcome.failed;
    }
  }

  /// Baixa para uma pasta privada do app. Devolve `null` em qualquer falha
  /// parcial (o arquivo incompleto é apagado — nunca entrega APK truncado).
  Future<File?> _download(
    AppRelease release, {
    ValueChanged<double>? onProgress,
  }) async {
    File? target;
    try {
      final dir = await _updatesDir();
      // Um APK por vez: limpa versões antigas (~80 MB cada).
      await for (final e in dir.list()) {
        if (e is File && e.path.toLowerCase().endsWith('.apk')) {
          try {
            await e.delete();
          } catch (_) {}
        }
      }
      target = File(
        '${dir.path}${Platform.pathSeparator}lifo-${release.version}.apk',
      );
      if (await target.exists()) await target.delete();

      final client = http.Client();
      try {
        // URL única por release: o CDN da Hostinger já serviu o APK antigo
        // em cache após o deploy (loop "atualização disponível" infinito).
        final base = Uri.parse(release.apkUrl);
        final url = base.replace(queryParameters: {
          ...base.queryParameters,
          'v': '${release.version}-${release.build}',
        });
        final req = http.Request('GET', url);
        final res = await client
            .send(req)
            .timeout(const Duration(seconds: 30));
        if (res.statusCode != 200) return null;
        // Página de erro do servidor (.htaccess/404) vem como text/html:
        // baixar isso e mandar instalar daria "pacote inválido".
        final contentType = (res.headers['content-type'] ?? '').toLowerCase();
        if (contentType.contains('text/html')) return null;

        final total = res.contentLength ?? 0;
        var received = 0;
        final sink = target.openWrite();
        try {
          await for (final chunk in res.stream.timeout(
            const Duration(seconds: 60),
          )) {
            sink.add(chunk);
            received += chunk.length;
            if (total > 0) onProgress?.call(received / total);
          }
          await sink.flush();
        } finally {
          await sink.close();
        }
        if (received == 0) return null;
        onProgress?.call(1.0);
        return target;
      } finally {
        client.close();
      }
    } catch (_) {
      try {
        if (target != null && await target.exists()) await target.delete();
      } catch (_) {}
      return null;
    }
  }

  /// Pasta de download privada do app: `<raiz>/updates`.
  ///
  /// As duas raízes usadas aqui estão declaradas no FileProvider do Android
  /// (`android/app/src/main/res/xml/file_paths.xml`), senão o instalador não
  /// recebe o content:// e a instalação falha:
  ///   • externa → `getExternalFilesDir()` (`Android/data/<pkg>/files`);
  ///   • reserva → `getFilesDir()` (`<data>/files`).
  /// Atenção: `getApplicationDocumentsDirectory()` cai em `app_flutter`, que
  /// fica FORA dessas duas raízes — por isso não é usada.
  Future<Directory> _updatesDir() async {
    Directory? base;
    try {
      base = await getExternalStorageDirectory();
    } catch (_) {}
    base ??= await getApplicationSupportDirectory();
    final dir = Directory('${base.path}${Platform.pathSeparator}updates');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Só para testes: limpa o estado em memória.
  @visibleForTesting
  void debugReset() {
    availableUpdate.value = null;
    installedLabel.value = '';
    _installedVersion = '';
    _installedBuild = 0;
  }
}