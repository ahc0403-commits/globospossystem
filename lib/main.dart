import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'core/constants/app_constants.dart';
import 'core/router/app_router.dart';
import 'core/ui/app_theme.dart';

export 'core/ui/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Web에서는 .env 파일 로드 불필요.
  // Native test/runtime may inject values via --dart-define only, so missing
  // .env must not prevent boot.
  if (!kIsWeb) {
    try {
      await dotenv.load(fileName: '.env');
    } catch (_) {
      // Fall back to dart-defines or defaults in AppConstants.
    }
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
      theme: AppTheme.build(),
      routerConfig: router,
    );
  }
}
