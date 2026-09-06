import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/connectivity_service.dart';
import 'package:globos_pos_system/core/services/live_refresh_service.dart';
import 'package:globos_pos_system/features/admin/admin_screen.dart';
import 'package:globos_pos_system/features/admin/providers/admin_audit_provider.dart';
import 'package:globos_pos_system/features/admin/providers/menu_provider.dart';
import 'package:globos_pos_system/features/admin/providers/tables_provider.dart';
import 'package:globos_pos_system/features/auth/auth_provider.dart';
import 'package:globos_pos_system/features/auth/auth_state.dart';
import 'package:globos_pos_system/features/auth/login_screen.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Auth extends AuthNotifier {
  _Auth() {
    state = const PosAuthState(role: 'store_admin', storeId: 'store-a');
  }
  int loginCalls = 0;
  @override
  Future<void> login(String email, String password) async {
    loginCalls++;
    state = state.copyWith(isLoading: true);
  }

  void changeStore() => state = state.copyWith(storeId: 'store-b');
}

class _Tables extends TablesNotifier {
  _Tables(super.storeId) {
    state = const TablesState(isLoading: true);
  }
  @override
  Future<void> fetchTables({bool showLoading = true}) async {}
  void fail() => state = const TablesState(error: 'Connection failed');
}

class _Menu extends MenuNotifier {
  _Menu(super.storeId);
  @override
  Future<void> fetchAll() async {}
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'http://localhost:54321',
      anonKey: 'test-anon',
      authOptions: const FlutterAuthClientOptions(
        detectSessionInUri: false,
        localStorage: EmptyLocalStorage(),
        autoRefreshToken: false,
      ),
    );
  });

  testWidgets(
    'slow and failed first tab keeps menu visible and unvisited tabs unmounted',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      final auth = _Auth();
      final tables = <String, _Tables>{};
      var menuLoads = 0;
      final router = GoRouter(
        routes: [GoRoute(path: '/', builder: (_, _) => const AdminScreen())],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authProvider.overrideWith((ref) => auth),
            connectivityProvider.overrideWith((ref) => Stream.value(true)),
            posLiveEventsProvider.overrideWith(
              (ref, store) => const Stream.empty(),
            ),
            adminAuditTraceProvider.overrideWith((ref, store) async => []),
            tablesProvider.overrideWith(
              (ref, store) => tables.putIfAbsent(store, () => _Tables(store)),
            ),
            menuProvider.overrideWith((ref, store) {
              menuLoads++;
              return _Menu(store);
            }),
          ],
          child: MaterialApp.router(
            routerConfig: router,
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
          ),
        ),
      );
      await tester.pump();
      final selector = find.byKey(const Key('toast_compact_section_selector'));
      void expectMenuVisible() {
        expect(selector.hitTestable(), findsOneWidget);
        final rect = tester.getRect(selector);
        expect(rect.top, greaterThanOrEqualTo(0));
        expect(rect.bottom, lessThanOrEqualTo(tester.view.physicalSize.height));
        expect(tester.takeException(), isNull);
      }

      expectMenuVisible();
      for (final key in [
        'admin_menu_root',
        'staff_root',
        'reports_root',
        'attendance_root',
        'settings_root',
        'einvoice_root',
      ]) {
        expect(find.byKey(Key(key), skipOffstage: false), findsNothing);
      }
      expect(menuLoads, 0);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pump();
      expectMenuVisible();
      tester.view.resetViewInsets();
      await tester.pump(const Duration(seconds: 10));
      expectMenuVisible();
      tables['store-a']!.fail();
      await tester.pump();
      expectMenuVisible();
      await tester.tap(selector);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.text('Menu').last);
      await tester.pump();
      expect(menuLoads, 1);
      expect(find.byKey(const Key('admin_menu_root')), findsOneWidget);
      final firstMenuElement = tester.element(
        find.byKey(const Key('admin_menu_root')),
      );
      await tester.tap(selector);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.text('Tables').last);
      await tester.pump();
      await tester.tap(selector);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.text('Menu').last);
      await tester.pump();
      expect(menuLoads, 1);
      expect(
        tester.element(find.byKey(const Key('admin_menu_root'))),
        same(firstMenuElement),
      );
      auth.changeStore();
      await tester.pump();
      expect(menuLoads, 2);
      expect(
        tester.element(find.byKey(const Key('admin_menu_root'))),
        isNot(same(firstMenuElement)),
      );
      expectMenuVisible();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets('login dismisses input focus before waiting for authentication', (
    tester,
  ) async {
    final auth = _Auth();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [authProvider.overrideWith((ref) => auth)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const LoginScreen(),
        ),
      ),
    );
    final password = find.byKey(const Key('login_password_field'));
    await tester.enterText(password, 'test-password');
    final editable = tester.widget<EditableText>(
      find.descendant(of: password, matching: find.byType(EditableText)),
    );
    expect(editable.focusNode.hasFocus, isTrue);
    await tester.tap(find.byKey(const Key('login_submit_button')));
    await tester.pump();
    expect(editable.focusNode.hasFocus, isFalse);
    expect(auth.loginCalls, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
