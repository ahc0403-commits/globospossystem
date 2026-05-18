import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'core/constants/app_constants.dart';
import 'core/i18n/locale_controller.dart';
import 'core/router/app_router.dart';
import 'core/ui/app_theme.dart';
import 'l10n/app_localizations.dart';

export 'core/ui/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Web debug runs still need the public Supabase config to boot locally.
  // Only the checked-in `.env` is loaded on web; native keeps its local-first
  // fallback order.
  final envCandidates = kIsWeb
      ? const ['.env']
      : const ['.env.local', '.env'];
  for (final fileName in envCandidates) {
    try {
      await dotenv.load(fileName: fileName);
      break;
    } catch (_) {
      // Try the next local env source before falling back to dart-defines.
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

class GlobosPosApp extends ConsumerWidget {
  const GlobosPosApp({super.key, required this.router});
  final dynamic router;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final localeState = ref.watch(localeControllerProvider);

    return MaterialApp.router(
      title: 'GLOBOS POS',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.build(),
      locale: localeState.locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      routerConfig: router,
    );
  }
}
