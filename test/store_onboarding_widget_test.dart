import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/super_admin/store_onboarding.dart';
import 'package:globos_pos_system/features/super_admin/super_admin_provider.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Admin extends SuperAdminNotifier {
  _Admin() {
    state = SuperAdminState(
      reportStart: DateTime(2026),
      reportEnd: DateTime(2026),
      brands: const [
        {
          'id': 'brand',
          'name': 'JeonGabok',
          'code': 'jeongabok',
          'short_code': 'JG',
        },
      ],
      taxEntities: const [
        SuperTaxEntity(
          id: 'entity',
          name: 'AKJ',
          taxCode: 'code',
          ownerType: 'internal',
        ),
      ],
      taxEntityBrands: const [
        SuperTaxEntityBrand(taxEntityId: 'entity', brandId: 'brand'),
      ],
    );
  }
  int loads = 0;
  @override
  Future<void> loadAllRestaurants({bool force = false}) async {
    loads++;
  }
}

class _Service extends StoreOnboardingService {
  _Service()
    : super(
        SupabaseClient(
          'http://localhost:54321',
          'fixture',
          authOptions: const AuthClientOptions(autoRefreshToken: false),
        ),
      );
  int creates = 0, runs = 0, previews = 0;
  bool fail = false;
  bool lostCreate = false;
  Completer<void>? pending;
  Map<String, dynamic>? input;
  @override
  Future<List<Map<String, dynamic>>> preview(
    String brand,
    String code,
    List<String> floors,
  ) async {
    previews++;
    return [
      {
        'account_code': 'jg_bm1',
        'display_name': 'Brand Manager',
        'scope': 'brand',
      },
      {
        'account_code': '${code.toLowerCase()}_sm1',
        'display_name': 'Store Manager',
        'scope': 'store',
      },
      for (final f in floors)
        {
          'account_code': '${code.toLowerCase()}_floor_${f.toLowerCase()}',
          'display_name': f,
          'scope': 'store',
        },
    ];
  }

  @override
  Future<String> create(Map<String, dynamic> values) async {
    creates++;
    input = values;
    await pending?.future;
    if (lostCreate) throw Exception('lost acknowledgement');
    return 'store';
  }

  @override
  Future<Map<String, dynamic>> status(String job) async => {
    'job_id': job,
    'store_id': 'store',
    'status': 'pending',
    'items': <Map<String, dynamic>>[],
  };
  @override
  Future<Map<String, dynamic>> run(String job) async {
    runs++;
    if (fail) throw Exception('offline');
    return {
      'job_id': job,
      'store_id': 'store',
      'status': 'complete',
      'items': [
        {
          'account_code': 'jgbt_sm1',
          'display_name': 'Store Manager',
          'ready': true,
        },
      ],
    };
  }

  @override
  Future<Map<String, dynamic>?> forStore(String store) async => {
    'job_id': 'existing-job',
    'store_id': store,
    'status': 'partial',
    'items': [
      {'account_code': 'jgbt_sm1', 'ready': false},
    ],
  };
}

Future<void> _mount(
  WidgetTester tester,
  _Service service,
  _Admin admin, {
  String? storeId,
}) async {
  tester.view.physicalSize = const Size(1000, 1500);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        superAdminProvider.overrideWith((ref) => admin),
        storeOnboardingServiceProvider.overrideWithValue(service),
      ],
      child: MaterialApp(
        locale: const Locale('ko'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: Scaffold(body: StoreOnboardingDialog(storeId: storeId)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String key) async {
  final f = find.byKey(Key(key));
  await tester.ensureVisible(f);
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Future<void> _fill(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const Key('store_name')),
    'JeonGabok Binh Thanh',
  );
  await tester.enterText(
    find.byKey(const Key('store_address')),
    '29A Nguyen Gia Tri',
  );
  await tester.enterText(find.byKey(const Key('store_abbreviation')), 'JGBT');
  await _tap(tester, 'onboarding_preview');
}

void main() {
  testWidgets(
    'preview IDs before save; one create on double click; no client password',
    (tester) async {
      final service = _Service();
      final admin = _Admin();
      await _mount(tester, service, admin);
      await _fill(tester);
      expect(find.text('jgbt_floor_3f@globos.world'), findsOneWidget);
      service.pending = Completer<void>();
      final save = find.byKey(const Key('onboarding_save'));
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pump();
      await tester.tap(save);
      await tester.pump();
      expect(service.creates, 1);
      service.pending!.complete();
      await tester.pumpAndSettle();
      expect(service.input!['p_code'], 'JGBT');
      expect(service.input!.keys.any((k) => k.contains('password')), isFalse);
      expect(service.runs, 1);
      expect(admin.loads, 1);
      expect(find.textContaining('생성 완료'), findsOneWidget);
    },
  );
  testWidgets('partial failure resumes without another store create', (
    tester,
  ) async {
    final service = _Service()..fail = true;
    final admin = _Admin();
    await _mount(tester, service, admin);
    await _fill(tester);
    await _tap(tester, 'onboarding_save');
    expect(find.byKey(const Key('onboarding_error')), findsOneWidget);
    service.fail = false;
    await _tap(tester, 'onboarding_save');
    expect(service.creates, 1);
    expect(service.runs, 2);
    expect(admin.loads, 1);
  });
  testWidgets('resume existing onboarding after page reload', (tester) async {
    final service = _Service();
    await _mount(tester, service, _Admin(), storeId: 'existing-store');
    expect(find.byKey(const Key('store_onboarding_dialog')), findsOneWidget);
    await _tap(tester, 'onboarding_save');
    expect(service.creates, 0);
    expect(service.runs, 1);
  });
  testWidgets('lost create response recovers committed job before retry', (
    tester,
  ) async {
    final service = _Service()..lostCreate = true;
    final admin = _Admin();
    await _mount(tester, service, admin);
    await _fill(tester);
    await _tap(tester, 'onboarding_save');
    service.lostCreate = false;
    await _tap(tester, 'onboarding_save');
    expect(service.creates, 1);
    expect(service.runs, 1);
    expect(admin.loads, 1);
  });
  testWidgets(
    'changing abbreviation invalidates preview and requires a new preview',
    (tester) async {
      final service = _Service();
      await _mount(tester, service, _Admin());
      await _fill(tester);
      await tester.enterText(
        find.byKey(const Key('store_abbreviation')),
        'JG02',
      );
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('onboarding_save')))
            .onPressed,
        isNull,
      );
    },
  );
}
