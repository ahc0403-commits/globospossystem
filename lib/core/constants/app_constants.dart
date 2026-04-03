import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

class AppConstants {
  static const String _supabaseUrlFallback =
      'https://ynriuoomotxuwhuxxmhj.supabase.co';
  static const String _supabaseAnonKeyFallback =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9'
      '.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Inlucml1b29tb3R4dXdodXh4bWhqIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzUwOTMxNTcsImV4cCI6MjA5MDY2OTE1N30'
      '.U8zP57ff3m190C6seRTUn4COpFNd6Zyd6M5KGtTNI18';

  // Web에서는 fallback 상수 사용 (anon key는 공개 가능)
  // Native에서는 .env에서 읽음
  static String get supabaseUrl {
    if (kIsWeb) return _supabaseUrlFallback;
    return dotenv.env['SUPABASE_URL'] ?? _supabaseUrlFallback;
  }

  static String get supabaseAnonKey {
    if (kIsWeb) return _supabaseAnonKeyFallback;
    return dotenv.env['SUPABASE_ANON_KEY'] ?? _supabaseAnonKeyFallback;
  }
}
