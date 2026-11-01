import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'core/constants/app_constants.dart';
import 'core/auth/terminal_auth.dart';
import 'core/auth/operation_scope_provider.dart';
import 'core/hardware/print_agent_coordinator_provider.dart';
import 'core/i18n/locale_controller.dart';
import 'core/layout/platform_info.dart';
import 'core/router/app_router.dart';
import 'core/services/live_refresh_service.dart';
import 'core/services/bank_transfer_alert_coordinator.dart';
import 'core/ui/app_theme.dart';
import 'features/auth/auth_provider.dart';
import 'features/auth/operation_scope_binding.dart';
import 'features/auth/session_recovery_screen.dart';
import 'l10n/app_localizations.dart';

export 'core/ui/app_theme.dart';
export 'core/services/pos_backend.dart';

Future<void> main([List<String> args = const []]) async {
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
  final terminalAuth = await TerminalAuth.create(
    AppConstants.supabaseUrl,
    args,
  );
  await Supabase.initialize(
    url: AppConstants.supabaseUrl,
    anonKey: AppConstants.supabaseAnonKey,
    authOptions: terminalAuth.options,
  );
  final container = ProviderContainer(
    overrides: [
      operationScopeProvider.overrideWith(
        (ref) => bindOperationScope(ref, authProvider),
      ),
    ],
  );
  // Own the session listener before any router/domain reads are created.
  container.read(operationScopeProvider);
  final router = buildAppRouter(container);

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: GlobosPosApp(router: router),
    ),
  );
}

/// Supabase client 전역 접근용

class GlobosPosApp extends ConsumerStatefulWidget {
  const GlobosPosApp({super.key, required this.router});
  final dynamic router;

  @override
  ConsumerState<GlobosPosApp> createState() => _GlobosPosAppState();
}

class _GlobosPosAppState extends ConsumerState<GlobosPosApp>
    with WidgetsBindingObserver {
  bool _profileRefreshInFlight = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refreshProfile());
  }

  Future<void> _refreshProfile({bool force = true}) async {
    if (_profileRefreshInFlight) return;
    _profileRefreshInFlight = true;
    try {
      await ref.read(authProvider.notifier).refreshProfile(force: force);
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
    final alertStoreId =
        PlatformInfo.supportsBankTransferAlerts && auth.role == 'cashier'
        ? storeId
        : null;
    if (auth.user != null && storeId != null) {
      ref.listen<AsyncValue<PosLiveEvent>>(posLiveEventsProvider(storeId), (
        _,
        next,
      ) {
        next.whenData((event) {
          if (event.isFallback || event.affects({'staff', 'settings'})) {
            unawaited(_refreshProfile(force: !event.isFallback));
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
      builder: (context, child) => BankTransferAlertCoordinator(
        storeId: alertStoreId,
        child: localeState.isHydrated
            ? Stack(
                children: [
                  child ?? const SizedBox.shrink(),
                  const SessionRecoveryBanner(),
                ],
              )
            : const ColoredBox(color: Color(0xFF101114)),
      ),
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
