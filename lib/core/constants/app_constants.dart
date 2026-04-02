import 'package:flutter_dotenv/flutter_dotenv.dart';

class AppConstants {
  // Supabase
  static String get supabaseUrl =>
      dotenv.env['SUPABASE_URL'] ?? (throw Exception('SUPABASE_URL not set'));

  static String get supabaseAnonKey =>
      dotenv.env['SUPABASE_ANON_KEY'] ?? (throw Exception('SUPABASE_ANON_KEY not set'));
}
