import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'core/constants/app_constants.dart';
import 'core/hardware/print_agent_coordinator_provider.dart';
import 'core/i18n/locale_controller.dart';
import 'core/router/app_router.dart';
import 'core/services/live_refresh_service.dart';
import 'core/ui/app_theme.dart';
import 'features/auth/auth_provider.dart';
import 'l10n/app_localizations.dart';

export 'core/ui/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Prefer local env files when they are available, then fall back to
  // dart-defines. Web deployments inject Supabase config via dart-define so
  // local .env files are not bundled into the release asset set.
  const hasWebDartDefinedSupabaseConfig =
      kIsWeb &&
      String.fromEnvironment('SUPABASE_URL') != '' &&
      String.fromEnvironment('SUPABASE_ANON_KEY') != '';
  final envCandidates = hasWebDartDefinedSupabaseConfig
      ? const <String>[]
      : kIsWeb
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

class GlobosPosApp extends ConsumerStatefulWidget {
  const GlobosPosApp({super.key, required this.router});
  final dynamic router;

  @override
  ConsumerState<GlobosPosApp> createState() => _GlobosPosAppState();
}

class _GlobosPosAppState extends ConsumerState<GlobosPosApp> {
  bool _profileRefreshInFlight = false;

  Future<void> _refreshProfile() async {
    if (_profileRefreshInFlight) return;
    _profileRefreshInFlight = true;
    try {
      await ref.read(authProvider.notifier).refreshProfile();
    } finally {
      _profileRefreshInFlight = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    // App-root ownership keeps the designated device's print agent alive while
    // operators navigate between cashier, admin, and monitoring screens.
    ref.watch(printAgentCoordinatorProvider);
    final localeState = ref.watch(localeControllerProvider);
    final auth = ref.watch(authProvider);
    final storeId = auth.storeId;
    if (auth.user != null && storeId != null) {
      ref.listen<AsyncValue<PosLiveEvent>>(posLiveEventsProvider(storeId), (
        _,
        next,
      ) {
        next.whenData((event) {
          if (event.isFallback || event.affects({'staff', 'settings'})) {
            unawaited(_refreshProfile());
          }
        });
      });
    }

    return MaterialApp.router(
      title: 'GLOBOS POS',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.build(),
      scrollBehavior: const GlobosScrollBehavior(),
      locale: localeState.locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      routerConfig: widget.router,
    );
  }
}

class GlobosScrollBehavior extends MaterialScrollBehavior {
  const GlobosScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.stylus,
    PointerDeviceKind.unknown,
  };
}
