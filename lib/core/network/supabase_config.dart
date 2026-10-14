class SupabaseConfig {
  static const String projectUrl = 'https://sjbmweuszwxbkdimbwdg.supabase.co';
  static const String projectId = 'sjbmweuszwxbkdimbwdg';
  static const String anonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.e30.placeholder',
  );
  static const String mapboxAccessToken = String.fromEnvironment(
    'MAPBOX_ACCESS_TOKEN',
    defaultValue: '',
  );
}
