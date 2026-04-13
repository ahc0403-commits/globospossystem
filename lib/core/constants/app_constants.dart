import 'package:flutter_dotenv/flutter_dotenv.dart';

class AppConstants {
  static const String _officeSystemUrlFallback =
      'https://office.globos.vn/dashboard';
  static const String _officeKpiUrlFallback = 'https://office.globos.vn/kpi';

  // Web: --dart-define으로 빌드 시 주입
  // Native: .env 파일에서 읽음
  static const String _supabaseUrlFromDefine =
      String.fromEnvironment('SUPABASE_URL');
  static const String _supabaseAnonKeyFromDefine =
      String.fromEnvironment('SUPABASE_ANON_KEY');

  static String get supabaseUrl {
    if (_supabaseUrlFromDefine.isNotEmpty) return _supabaseUrlFromDefine;
    final envVal = dotenv.env['SUPABASE_URL'];
    if (envVal != null && envVal.isNotEmpty) return envVal;
    throw StateError(
        'SUPABASE_URL not configured. Set via --dart-define or .env');
  }

  static String get supabaseAnonKey {
    if (_supabaseAnonKeyFromDefine.isNotEmpty) return _supabaseAnonKeyFromDefine;
    final envVal = dotenv.env['SUPABASE_ANON_KEY'];
    if (envVal != null && envVal.isNotEmpty) return envVal;
    throw StateError(
        'SUPABASE_ANON_KEY not configured. Set via --dart-define or .env');
  }

  static String get officeSystemUrl {
    return dotenv.env['OFFICE_SYSTEM_URL'] ?? _officeSystemUrlFallback;
  }

  static String get officeKpiUrl {
    return dotenv.env['OFFICE_KPI_URL'] ?? _officeKpiUrlFallback;
  }
}
