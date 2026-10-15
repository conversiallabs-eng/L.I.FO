package com.lifo.lifo

import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest

class MainActivity : FlutterActivity() {
    companion object {
        const val CHANNEL = "com.lifo.app/attestation"
        const val INSTALLER_CHANNEL = "com.lifo.app/installer"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, CHANNEL
        ).setMethodCallHandler { call, result ->
            if (call.method == "getSigningCertSha1") {
                result.success(signingCertSha1())
            } else {
                result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, INSTALLER_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "canRequestPackageInstalls" -> result.success(canInstallPackages())
                "openUnknownSourcesSettings" -> result.success(openUnknownSourcesSettings())
                "installApk" -> result.success(installApk(call.argument<String>("path")))
                else -> result.notImplemented()
            }
        }
    }

    /// SHA-1 do certificado de assinatura (formato "AA:BB:..." maiúsculo),
    /// igual ao `keytool -list`. A CARTO usa para a trava de mobile app
    /// (header X-Android-Cert). Nulo se indisponível — o app segue sem ele.
    private fun signingCertSha1(): String? {
        return try {
            val pm = applicationContext.packageManager
            val pkg = applicationContext.packageName
            val sigs = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                val info = pm.getPackageInfo(
                    pkg, PackageManager.GET_SIGNING_CERTIFICATES
                )
                val signing = info.signingInfo
                if (signing != null && signing.hasMultipleSigners()) {
                    signing.apkContentsSigners
                } else {
                    signing?.signingCertificateHistory
                }
            } else {
                @Suppress("DEPRECATION")
                pm.getPackageInfo(pkg, PackageManager.GET_SIGNATURES)?.signatures
            } ?: return null
            if (sigs.isEmpty()) return null
            val md = MessageDigest.getInstance("SHA-1")
            val digest = md.digest(sigs[0].toByteArray())
            digest.joinToString(":") { "%02X".format(it) }
        } catch (_: Exception) {
            null
        }
    }

    /// O sistema autoriza este app a instalar pacotes? Abaixo do Android 8
    /// (API 26) a autorização não existe e vale como concedida.
    private fun canInstallPackages(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return true
        return try {
            applicationContext.packageManager.canRequestPackageInstalls()
        } catch (_: Exception) {
            false
        }
    }

    /// Abre "Instalar apps desconhecidos" já apontando para este app.
    private fun openUnknownSourcesSettings(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        return try {
            val intent = Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES)
                .setData(Uri.parse("package:$packageName"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    /// Entrega o APK baixado ao instalador do pacote via FileProvider.
    ///
    /// file:// não vale mais (FileUriExposedException desde o Android 7), por
    /// isso o arquivo é exposto como content:// com grant só de leitura para
    /// quem recebe o intent.
    private fun installApk(path: String?): Boolean {
        if (path.isNullOrEmpty()) return false
        return try {
            val file = File(path)
            if (!file.exists() || file.length() <= 0L) return false
            val uri = FileProvider.getUriForFile(
                this, "$packageName.fileprovider", file
            )
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }
}
