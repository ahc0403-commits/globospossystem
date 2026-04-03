import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'core/constants/app_constants.dart';
import 'core/router/app_router.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Web에서는 .env 파일 로드 불필요 (상수로 처리)
  if (!kIsWeb) {
    await dotenv.load(fileName: '.env');
  }
  await Supabase.initialize(
    url: AppConstants.supabaseUrl,
    anonKey: AppConstants.supabaseAnonKey,
  );

  final container = ProviderContainer();
  final router = buildAppRouter(container);

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: GlobosPosApp(router: router),
    ),
  );
}

/// Supabase client 전역 접근용
final supabase = Supabase.instance.client;

class GlobosPosApp extends StatelessWidget {
  const GlobosPosApp({super.key, required this.router});
  final dynamic router;

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'GLOBOS POS',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: AppColors.amber500),
        useMaterial3: true,
        textTheme: GoogleFonts.notoSansKrTextTheme(),
      ),
      routerConfig: router,
    );
  }
}

/// 앱 전역 색상 상수
class AppColors {
  static const surface0        = Color(0xFF111210);
  static const surface1        = Color(0xFF1C1D1A);
  static const surface2        = Color(0xFF252621);
  static const textPrimary     = Color(0xFFF0EDE6);
  static const textSecondary   = Color(0xFF9E9B92);
  static const amber500        = Color(0xFFF5A623);
  static const statusAvailable = Color(0xFF4CAF7D);
  static const statusOccupied  = Color(0xFFE8935A);
  static const statusReady     = Color(0xFFF5A623);
  static const statusCancelled = Color(0xFFC0392B);
}
