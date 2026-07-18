import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/ui/app_theme.dart';
import 'package:globos_pos_system/features/auth/auth_provider.dart';
import 'package:globos_pos_system/features/auth/auth_state.dart';
import 'package:globos_pos_system/features/qc/qc_provider.dart';
import 'package:globos_pos_system/features/super_admin/super_admin_provider.dart';
import 'package:globos_pos_system/features/super_admin/super_admin_screen.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _storeId = '7f6c9d22-6d84-4c7f-b923-79c81c4015d1';
const _brandId = 'brand-globos';
const _taxEntityId = 'tax-entity-globos';

final _store = SuperRestaurant(
  id: _storeId,
  name: 'GLOBOS Nguyễn Huệ',
  slug: 'globos-nguyen-hue',
  address: '1 Nguyễn Huệ, Quận 1, TP.HCM',
  operationMode: 'standard',
  perPersonCharge: null,
  isActive: true,
  createdAt: DateTime(2026, 7, 18),
  brandId: _brandId,
  brandName: 'GLOBOS',
  brandCode: 'GLOBOS',
  taxEntityId: _taxEntityId,
  taxEntityName: 'GLOBOS Vietnam',
  taxCode: '0312345678',
  ownerType: 'internal',
);

class _AuthNotifier extends AuthNotifier {
  _AuthNotifier() : super() {
    state = const PosAuthState(role: 'super_admin');
  }
}

class _SuperAdminNotifier extends SuperAdminNotifier {
  _SuperAdminNotifier() {
    state = SuperAdminState(
      restaurants: [_store],
      brands: const [
        {'id': _brandId, 'name': 'GLOBOS', 'code': 'GLOBOS'},
      ],
      taxEntities: const [
        SuperTaxEntity(
          id: _taxEntityId,
          name: 'GLOBOS Vietnam',
          taxCode: '0312345678',
          ownerType: 'internal',
        ),
      ],
      taxEntityBrands: const [
        SuperTaxEntityBrand(taxEntityId: _taxEntityId, brandId: _brandId),
      ],
      reportStart: DateTime(2026, 7, 1),
      reportEnd: DateTime(2026, 7, 18),
    );
  }

  @override
  Future<void> loadAllRestaurants() async {}

  @override
  Future<void> loadBrands() async {}

  @override
  Future<void> loadLegalEntityStructure() async {}

  @override
  Future<void> loadAllReports({String? selectedRestaurantId}) async {}
}

class _TemplateNotifier extends QcTemplateNotifier {
  _TemplateNotifier() {
    state = const QcTemplateState();
  }
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'http://localhost:54321',
      anonKey: 'test-anon-key',
    );
  });

  testWidgets('all three Super Admin overlay entrypoints execute', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1440, 1000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final router = GoRouter(
      initialLocation: '/super-admin',
      routes: [
        GoRoute(
          path: '/super-admin',
          builder: (_, __) => const SuperAdminScreen(),
        ),
        GoRoute(
          path: '/admin/:storeId',
          builder: (_, __) => const Scaffold(body: SizedBox.shrink()),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith((ref) => _AuthNotifier()),
          superAdminProvider.overrideWith((ref) => _SuperAdminNotifier()),
          qcTemplateProvider.overrideWith((ref) => _TemplateNotifier()),
          globalQcTemplatesProvider.overrideWith((ref) async => const []),
        ],
        child: MaterialApp.router(
          debugShowCheckedModeBanner: false,
          theme: AppTheme.build(),
          locale: const Locale('vi'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final manage = find.byKey(const Key('super_admin_manage_store_$_storeId'));
    await tester.ensureVisible(manage);
    await tester.tap(manage);
    await tester.pumpAndSettle();
    final storeSheet = find.byKey(const Key('super_admin_store_sheet'));
    expect(storeSheet, findsOneWidget);

    final close = find.byKey(const Key('super_admin_close_store_button'));
    await tester.ensureVisible(close);
    await tester.tap(close);
    await tester.pumpAndSettle();
    final closeDialog = find.byKey(const Key('super_admin_close_store_dialog'));
    expect(closeDialog, findsOneWidget);
    Navigator.of(tester.element(closeDialog)).pop();
    await tester.pumpAndSettle();
    Navigator.of(tester.element(storeSheet)).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('super_admin_nav_qc_template')));
    await tester.pumpAndSettle();
    final templateAction = find.byKey(
      const Key('super_admin_global_template_add_action'),
    );
    await tester.ensureVisible(templateAction);
    await tester.tap(templateAction);
    await tester.pumpAndSettle();
    final templateSheet = find.byKey(
      const Key('super_admin_global_template_sheet'),
    );
    expect(templateSheet, findsOneWidget);
    Navigator.of(tester.element(templateSheet)).pop();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
