import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:globos_pos_system/core/services/live_refresh_service.dart';
import 'package:globos_pos_system/core/ui/app_theme.dart';
import 'package:globos_pos_system/features/auth/auth_provider.dart';
import 'package:globos_pos_system/features/auth/auth_state.dart';
import 'package:globos_pos_system/features/super_admin/brand_service.dart';
import 'package:globos_pos_system/features/super_admin/super_admin_provider.dart';
import 'package:globos_pos_system/features/super_admin/super_admin_screen.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const entityId = '40000000-0000-4000-8000-000000000001';
const groupId = '30000000-0000-4000-8000-000000000001';

class _Auth extends AuthNotifier {
  _Auth() {
    state = const PosAuthState(role: 'super_admin');
  }
}

class _Admin extends SuperAdminNotifier {
  _Admin() {
    state = SuperAdminState(
      reportStart: DateTime(2026),
      reportEnd: DateTime(2026),
      taxEntities: const [
        SuperTaxEntity(
          id: entityId,
          name: 'AKJ',
          taxCode: '0312345678',
          ownerType: 'internal',
        ),
      ],
    );
  }
  int storeLoads = 0;
  @override
  Future<void> loadBrands({bool force = false}) async {}
  @override
  Future<void> loadLegalEntityStructure({bool force = false}) async {}
  @override
  Future<void> loadAllRestaurants({bool force = false}) async {
    storeLoads++;
  }

  @override
  Future<void> loadAllReports({String? selectedRestaurantId}) async {}
  SuperAdminState get snapshot => state;
}

class _Brands extends BrandService {
  _Brands() : super(Supabase.instance.client);
  final rows = <Map<String, dynamic>>[];
  int creates = 0;
  int lists = 0;
  bool failList = false;
  bool failCreate = false;
  bool noGroups = false;
  Future<BrandPage> Function(String search, Map<String, dynamic>? after)?
  onList;
  Completer<void>? pending;
  final requestIds = <String>[];
  @override
  Future<List<Map<String, dynamic>>> groups() async => noGroups
      ? []
      : [
          {'id': groupId, 'name': 'Group', 'company_name': 'GLOBOS'},
        ];
  @override
  Future<BrandPage> list({
    String search = '',
    Map<String, dynamic>? after,
  }) async {
    lists++;
    if (onList != null) return onList!(search, after);
    if (failList) throw Exception('offline');
    return BrandPage(
      rows
          .where(
            (r) => '${r['name']} ${r['code']}'.toLowerCase().contains(
              search.toLowerCase(),
            ),
          )
          .toList(),
      false,
    );
  }

  @override
  Future<Map<String, dynamic>> create({
    required String id,
    required String name,
    required String code,
    required String groupId,
    required List<String> taxEntityIds,
  }) async {
    creates++;
    requestIds.add(id);
    await pending?.future;
    if (failCreate) throw Exception('BRAND_CODE_EXISTS');
    final row = {
      'id': id,
      'name': name,
      'code': code.toLowerCase(),
      'brand_master_id': groupId,
      'tax_entity_ids': taxEntityIds,
      'tax_entity_names': <String>[],
      'store_count': 0,
    };
    rows.add(row);
    return row;
  }

  @override
  Future<Map<String, dynamic>> link({
    required String brandId,
    required List<String> taxEntityIds,
  }) async {
    final row = rows.singleWhere((r) => r['id'] == brandId);
    row['tax_entity_ids'] = {
      ...(row['tax_entity_ids'] as List).cast<String>(),
      ...taxEntityIds,
    }.toList();
    return row;
  }
}

Future<void> _mount(
  WidgetTester tester,
  _Admin admin,
  _Brands service, {
  String locale = 'ko',
  Size size = const Size(1280, 1000),
  double scale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  final router = GoRouter(
    routes: [GoRoute(path: '/', builder: (_, __) => const SuperAdminScreen())],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith((ref) => _Auth()),
        superAdminProvider.overrideWith((ref) => admin),
        brandServiceProvider.overrideWithValue(service),
      ],
      child: MaterialApp.router(
        theme: AppTheme.build(),
        locale: Locale(locale),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String key) async {
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _fill(WidgetTester tester) async {
  await tester.enterText(find.byKey(const Key('brand_name')), 'JeonGabok');
  await tester.enterText(find.byKey(const Key('brand_code')), 'JEONGABOK');
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    if (const bool.fromEnvironment('BRAND_SCREENSHOT')) {
      await (FontLoader('Pretendard')
            ..addFont(rootBundle.load('assets/fonts/PretendardVariable.ttf')))
          .load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    }
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'http://localhost:54321',
      anonKey: 'fixture',
    );
  });

  for (final scenario in [
    (locale: 'ko', size: const Size(1280, 1000), scale: 1.0),
    (locale: 'en', size: const Size(390, 844), scale: 1.0),
    (locale: 'vi', size: const Size(320, 800), scale: 1.5),
  ]) {
    testWidgets(
      'register without a store then link and select: ${scenario.locale}',
      (tester) async {
        final admin = _Admin();
        final service = _Brands();
        await _mount(
          tester,
          admin,
          service,
          locale: scenario.locale,
          size: scenario.size,
          scale: scenario.scale,
        );
        await _tap(tester, 'super_admin_add_brand_action');
        await _fill(tester);
        if (const bool.fromEnvironment('BRAND_SCREENSHOT')) {
          await tester.pumpAndSettle();
          await expectLater(
            find.byKey(const Key('brand_editor_dialog')),
            matchesGoldenFile(
              '../outputs/independent-brand/brand_editor_${scenario.locale}.png',
            ),
          );
        }
        await _tap(tester, 'brand_save');
        expect(find.byKey(const Key('brand_editor_dialog')), findsNothing);
        expect(service.creates, 1);
        expect(service.rows.single['tax_entity_ids'], isEmpty);
        expect(admin.snapshot.restaurants, isEmpty);
        expect(admin.snapshot.brands, hasLength(1));
        expect(
          admin.storeLoads,
          1,
          reason: 'Brand writes do not reload stores',
        );
        await _tap(tester, 'super_admin_manage_brands_action');
        final id = service.rows.single['id'];
        expect(find.byKey(ValueKey('brand_row_$id')), findsOneWidget);
        await _tap(tester, 'brand_link_$id');
        await _tap(tester, 'brand_entity_$entityId');
        await _tap(tester, 'brand_save');
        expect(admin.snapshot.brandsForTaxEntity(entityId).single['id'], id);
        final dialogContext = tester.element(
          find.byKey(const Key('brand_management_dialog')),
        );
        Navigator.pop(dialogContext);
        await tester.pumpAndSettle();
        await _tap(tester, 'super_admin_add_store_action');
        expect(find.text('JeonGabok (jeongabok)'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'store draft survives nested brand registration and selects its result',
    (tester) async {
      final admin = _Admin();
      final service = _Brands();
      await _mount(tester, admin, service);
      await _tap(tester, 'super_admin_add_store_action');
      await tester.enterText(find.byKey(const Key('store_name')), 'Binh Thanh');
      await tester.enterText(
        find.byKey(const Key('store_address')),
        '29A Nguyen Gia Tri',
      );
      await tester.enterText(find.byKey(const Key('store_slug')), 'binh-thanh');
      await _tap(tester, 'store_add_brand');
      await _fill(tester);
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const Key('brand_entity_$entityId')),
            )
            .value,
        isTrue,
      );
      await _tap(tester, 'brand_save');
      expect(find.text('JeonGabok (jeongabok)'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('store_name')))
            .controller!
            .text,
        'Binh Thanh',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('store_address')))
            .controller!
            .text,
        '29A Nguyen Gia Tri',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('store_slug')))
            .controller!
            .text,
        'binh-thanh',
      );
      expect(admin.snapshot.restaurants, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'double click sends one write; failure retains input and retry request id',
    (tester) async {
      final admin = _Admin();
      final service = _Brands();
      await _mount(tester, admin, service);
      await _tap(tester, 'super_admin_add_brand_action');
      await _fill(tester);
      service.pending = Completer<void>();
      service.failCreate = true;
      await tester.tap(find.byKey(const Key('brand_save')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('brand_save')));
      await tester.pump();
      expect(service.creates, 1);
      service.pending!.complete();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('brand_editor_error')), findsOneWidget);
      expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('brand_name')))
            .controller!
            .text,
        'JeonGabok',
      );
      service.failCreate = false;
      service.pending = null;
      await _tap(tester, 'brand_save');
      expect(service.creates, 2);
      expect(service.requestIds.toSet(), hasLength(1));
      expect(service.rows, hasLength(1));
    },
  );

  testWidgets('validation, missing groups and failed list are visible', (
    tester,
  ) async {
    final admin = _Admin();
    final service = _Brands();
    service.noGroups = true;
    await _mount(tester, admin, service);
    await _tap(tester, 'super_admin_add_brand_action');
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('brand_save')))
          .onPressed,
      isNull,
    );
    Navigator.pop(tester.element(find.byKey(const Key('brand_editor_dialog'))));
    await tester.pumpAndSettle();
    service.failList = true;
    await _tap(tester, 'super_admin_manage_brands_action');
    expect(find.byKey(const Key('brand_list_error')), findsOneWidget);
    final l10n = AppLocalizations.of(
      tester.element(find.byKey(const Key('brand_management_dialog'))),
    )!;
    expect(find.text(l10n.brandListEmpty), findsNothing);
    service.failList = false;
    await tester.tap(find.text(l10n.retry));
    await tester.pumpAndSettle();
    expect(find.text(l10n.brandListEmpty), findsOneWidget);
  });

  testWidgets(
    'brand management loads the next cursor page without per-row requests',
    (tester) async {
      final admin = _Admin();
      final service = _Brands();
      Map<String, dynamic> row(String id) => {
        'id': id,
        'name': id,
        'code': id,
        'tax_entity_ids': <String>[],
        'tax_entity_names': <String>[],
        'store_count': 0,
      };
      Map<String, dynamic>? cursor;
      service.onList = (search, after) async {
        cursor = after;
        return after == null
            ? BrandPage(List.generate(50, (i) => row('page-$i')), true)
            : BrandPage([row('second-page')], false);
      };
      await _mount(tester, admin, service);
      await _tap(tester, 'super_admin_manage_brands_action');
      expect(service.lists, 1);
      await _tap(tester, 'brand_load_more');
      expect(service.lists, 2);
      expect(cursor?['id'], 'page-49');
      final target = find.byKey(const Key('brand_row_second-page'));
      await tester.scrollUntilVisible(
        target,
        400,
        scrollable: find
            .descendant(
              of: find.byKey(const Key('brand_management_dialog')),
              matching: find.byType(Scrollable),
            )
            .last,
      );
      expect(target, findsOneWidget);
      expect(find.byKey(const Key('brand_load_more')), findsNothing);
    },
  );

  testWidgets(
    'debounced search ignores a late result from the previous query',
    (tester) async {
      final admin = _Admin();
      final service = _Brands();
      final older = Completer<BrandPage>();
      service.onList = (search, after) async {
        if (search == 'older') return older.future;
        return BrandPage(
          search.isEmpty
              ? []
              : [
                  {
                    'id': 'latest',
                    'name': 'Latest result',
                    'code': 'latest',
                    'tax_entity_ids': <String>[],
                    'tax_entity_names': <String>[],
                    'store_count': 0,
                  },
                ],
          false,
        );
      };
      await _mount(tester, admin, service);
      await _tap(tester, 'super_admin_manage_brands_action');
      await tester.enterText(find.byKey(const Key('brand_search')), 'older');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.enterText(find.byKey(const Key('brand_search')), 'latest');
      older.complete(
        BrandPage([
          {
            'id': 'older',
            'name': 'Old result',
            'code': 'older',
            'tax_entity_ids': <String>[],
            'tax_entity_names': <String>[],
            'store_count': 0,
          },
        ], false),
      );
      await tester.pump();
      expect(find.text('Old result (older)'), findsNothing);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('brand_row_latest')), findsOneWidget);
      expect(service.lists, 3);
    },
  );

  test(
    'brand event batches preserve targeted refresh and fallback semantics',
    () {
      const brand = PosLiveEvent(
        domain: 'settings',
        sourceTable: 'brands',
        eventType: 'INSERT',
      );
      const link = PosLiveEvent(
        domain: 'settings',
        sourceTable: 'tax_entity_brands',
        eventType: 'INSERT',
      );
      const other = PosLiveEvent(
        domain: 'settings',
        sourceTable: 'restaurants',
        eventType: 'UPDATE',
      );
      expect(
        brand.merge(link).onlySourceTables({'brands', 'tax_entity_brands'}),
        isTrue,
      );
      expect(
        brand.merge(other).onlySourceTables({'brands', 'tax_entity_brands'}),
        isFalse,
      );
      expect(
        brand.merge(const PosLiveEvent.fallback()).onlySourceTables({
          'brands',
          'tax_entity_brands',
        }),
        isFalse,
      );
    },
  );
}
