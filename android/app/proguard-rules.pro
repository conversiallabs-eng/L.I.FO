# ============================================================================
# LIFO HARDENING & OBFUSCATION RULES (R8 AGGRESSIVE)
# ============================================================================

# Otimização agressiva em múltiplos passos
-optimizationpasses 5
-allowaccessmodification
-repackageclasses 'com.lifo.sec'

# Não gerar nomes de classes e métodos inteligíveis
-overloadaggressively

# Strip de metadados e números de linha de depuração
-renamesourcefileattribute SourceFile
-keepattributes !SourceFile,!LineNumberTable,!LocalVariableTable,!LocalVariableTypeTable

# Remover todas as chamadas de Log de depuração em tempo de compilação
-assumenosideeffects class android.util.Log {
    public static boolean isLoggable(java.lang.String, int);
    public static int v(...);
    public static int d(...);
    public static int i(...);
    public static int w(...);
    public static int e(...);
}

# Flutter Framework Essenciais (não quebrar canais nativos)
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }

# Proteger o SQLite FFI e Criptografia Nativa
-keep class com.tekartik.sqflite.** { *; }
-keep class net.sqlcipher.** { *; }

# Play Core referenciado pelo engine Flutter (deferred components, não
# usado pelo app). Sem estes -dontwarn, o R8 aborta o release. Gerado pelo
# próprio AGP em build/app/outputs/mapping/release/missing_rules.txt.
-dontwarn com.google.android.play.core.splitcompat.SplitCompatApplication
-dontwarn com.google.android.play.core.splitinstall.SplitInstallException
-dontwarn com.google.android.play.core.splitinstall.SplitInstallManager
-dontwarn com.google.android.play.core.splitinstall.SplitInstallManagerFactory
-dontwarn com.google.android.play.core.splitinstall.SplitInstallRequest$Builder
-dontwarn com.google.android.play.core.splitinstall.SplitInstallRequest
-dontwarn com.google.android.play.core.splitinstall.SplitInstallSessionState
-dontwarn com.google.android.play.core.splitinstall.SplitInstallStateUpdatedListener
-dontwarn com.google.android.play.core.tasks.OnFailureListener
-dontwarn com.google.android.play.core.tasks.OnSuccessListener
-dontwarn com.google.android.play.core.tasks.Task
