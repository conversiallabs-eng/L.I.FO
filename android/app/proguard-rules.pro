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
