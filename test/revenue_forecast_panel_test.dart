import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/report/revenue_forecast/revenue_forecast_defaults_service.dart';
import 'package:globos_pos_system/features/report/revenue_forecast/revenue_forecast_engine.dart';
import 'package:globos_pos_system/features/report/revenue_forecast/revenue_forecast_panel.dart';
import 'package:globos_pos_system/features/report/revenue_forecast/revenue_forecast_profile_service.dart';
import 'package:globos_pos_system/features/report/report_excel_file.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';

class _MemoryProfileRepository implements RevenueForecastProfileRepository {
  RevenueForecastProfileSnapshot? snapshot;

  @override
  Future<RevenueForecastProfileSnapshot?> load(String storeId) async =>
      snapshot;

  @override
  Future<RevenueForecastProfileSnapshot> savePhoto({
    required String storeId,
    required int expectedRevision,
    required PhotoForecastProfile profile,
  }) async => snapshot = RevenueForecastProfileSnapshot(
    storeId: storeId,
    revision: expectedRevision + 1,
    businessType: ForecastBusinessType.photo,
    settings: photoProfileToJson(profile),
    effectiveFrom: DateTime.utc(2026, 1, 1),
  );

  @override
  Future<RevenueForecastProfileSnapshot> saveRestaurant({
    required String storeId,
    required int expectedRevision,
    required RestaurantForecastProfile profile,
  }) async => snapshot = RevenueForecastProfileSnapshot(
    storeId: storeId,
    revision: expectedRevision + 1,
    businessType: ForecastBusinessType.restaurant,
    settings: restaurantProfileToJson(profile),
    effectiveFrom: DateTime.utc(2026, 1, 1),
  );
}

class _DelayedProfileRepository implements RevenueForecastProfileRepository {
  final completer = Completer<RevenueForecastProfileSnapshot?>();

  @override
  Future<RevenueForecastProfileSnapshot?> load(String storeId) =>
      completer.future;

  @override
  Future<RevenueForecastProfileSnapshot> savePhoto({
    required String storeId,
    required int expectedRevision,
    required PhotoForecastProfile profile,
  }) => throw UnimplementedError();

  @override
  Future<RevenueForecastProfileSnapshot> saveRestaurant({
    required String storeId,
    required int expectedRevision,
    required RestaurantForecastProfile profile,
  }) => throw UnimplementedError();
}

class _MemoryDefaultsRepository implements RevenueForecastDefaultsRepository {
  _MemoryDefaultsRepository(this.defaults);

  final RevenueForecastOperationalDefaults? defaults;

  @override
  Future<RevenueForecastOperationalDefaults?> loadRestaurant({
    required String storeId,
    required DateTime trainingStart,
    required DateTime trainingEnd,
    required List<RevenueForecastObservation> observations,
  }) async => defaults;
}

RevenueForecastOperationalDefaults _periodDefaults(
  RestaurantForecastProfile profile, {
  Set<RevenueForecastInputField> unavailable = const {
    RevenueForecastInputField.paymentWaitMinutes,
    RevenueForecastInputField.cleanupMinutes,
  },
}) => RevenueForecastOperationalDefaults(
  profile: profile,
  usesMeasuredOperations: true,
  usesFallbackAssumptions: false,
  periodStart: DateTime.utc(2026, 7, 1),
  periodEnd: DateTime.utc(2026, 8, 4),
  evidence: {
    for (final field in RevenueForecastInputField.values)
      field: RevenueForecastInputEvidence(
        source:
            field == RevenueForecastInputField.floorLabel ||
                field == RevenueForecastInputField.tableCount
            ? RevenueForecastInputSource.registeredConfiguration
            : unavailable.contains(field)
            ? RevenueForecastInputSource.unavailable
            : RevenueForecastInputSource.selectedPeriodAverage,
        sampleCount: unavailable.contains(field) ? 0 : 30,
        observedDays: unavailable.contains(field) ? 0 : 20,
        isProxy:
            field == RevenueForecastInputField.firstServeMinutes ||
            field == RevenueForecastInputField.operatingMinutes,
      ),
  },
);

class _LocaleSwitchHost extends StatefulWidget {
  const _LocaleSwitchHost({required this.repository});

  final RevenueForecastProfileRepository repository;

  @override
  State<_LocaleSwitchHost> createState() => _LocaleSwitchHostState();
}

class _LocaleSwitchHostState extends State<_LocaleSwitchHost> {
  Locale locale = const Locale('en');

  @override
  Widget build(BuildContext context) {
    final start = DateTime.utc(2026, 7, 1);
    return MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SingleChildScrollView(
          child: Column(
            children: [
              TextButton(
                key: const Key('switch_forecast_locale'),
                onPressed: () => setState(() => locale = const Locale('ko')),
                child: const Text('Switch locale'),
              ),
              RevenueForecastPanel(
                key: const Key('locale_forecast_panel'),
                storeId: '00000000-0000-0000-0000-000000000001',
                businessType: ForecastBusinessType.restaurant,
                trainingStart: start,
                trainingEnd: start.add(const Duration(days: 34)),
                observations: _observations(start, 35),
                canSaveProfile: true,
                profileRepository: widget.repository,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

List<RevenueForecastObservation> _observations(
  DateTime start,
  int days, {
  bool photo = false,
}) => List.generate(days, (index) {
  final units = 10 + index % 7 + index / 10;
  return RevenueForecastObservation(
    date: start.add(Duration(days: index)),
    revenueVnd: photo
        ? units * photoRevenuePerPaidSessionVnd
        : 2000000 + index * 50000,
    dineInRevenueVnd: photo ? 0 : 1400000 + index * 35000,
    units: photo ? units : null,
  );
});

Future<void> _pumpPanel(
  WidgetTester tester, {
  required ForecastBusinessType type,
  required Locale locale,
  required double width,
  double textScale = 1,
  ReportExcelFileSaver? saveExcelFile,
  RevenueForecastDefaultsRepository? defaultsRepository,
  RevenueForecastProfileRepository? profileRepository,
}) async {
  final start = DateTime.utc(2026, 7, 1);
  final repository = profileRepository ?? _MemoryProfileRepository();
  tester.view.physicalSize = Size(width, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          child: RevenueForecastPanel(
            storeId: '00000000-0000-0000-0000-000000000001',
            businessType: type,
            trainingStart: start,
            trainingEnd: start.add(const Duration(days: 34)),
            observations: _observations(
              start,
              35,
              photo: type == ForecastBusinessType.photo,
            ),
            canSaveProfile: true,
            profileRepository: repository,
            defaultsRepository: defaultsRepository,
            saveExcelFile: saveExcelFile,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _selectAllOperatingWeekdays(
  WidgetTester tester,
  ForecastBusinessType type,
) async {
  final prefix = type == ForecastBusinessType.restaurant
      ? 'restaurant'
      : 'photo';
  for (var weekday = DateTime.monday; weekday <= DateTime.sunday; weekday++) {
    final chip = find.byKey(Key('revenue_forecast_weekday_${prefix}_$weekday'));
    await tester.ensureVisible(chip);
    await tester.tap(chip);
    await tester.pump();
  }
}

void main() {
  testWidgets('restaurant settings use operational defaults automatically', (
    tester,
  ) async {
    const defaultProfile = RestaurantForecastProfile(
      floors: [
        RestaurantFloorCapacity(
          label: 'G',
          tableCount: 14,
          serviceUnitsPerHour: 18,
        ),
        RestaurantFloorCapacity(
          label: '1F',
          tableCount: 9,
          serviceUnitsPerHour: 12,
        ),
      ],
      seatedToFirstServeMinutes: 12,
      diningMinutes: 48,
      paymentWaitMinutes: 0,
      cleanupMinutes: 0,
      kitchenUnitsPerHour: 32,
      checkerUnitsPerHour: 30,
      operatingMinutesPerDay: 720,
      operatingWeekdays: {1, 2, 3, 4, 5, 6, 7},
      averageTicketVnd: 285000,
    );
    await _pumpPanel(
      tester,
      type: ForecastBusinessType.restaurant,
      locale: const Locale('ko'),
      width: 1024,
      defaultsRepository: _MemoryDefaultsRepository(
        _periodDefaults(defaultProfile),
      ),
    );

    expect(
      find.byKey(const Key('revenue_forecast_defaults_applied')),
      findsOneWidget,
    );
    expect(find.textContaining('측정 가능한 평균만 적용'), findsOneWidget);
    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(14));
    expect(tester.widget<TextField>(fields.at(0)).controller!.text, 'G');
    expect(tester.widget<TextField>(fields.at(1)).controller!.text, '14');
    expect(tester.widget<TextField>(fields.at(3)).controller!.text, '1F');
    expect(tester.widget<TextField>(fields.at(4)).controller!.text, '9');
    expect(tester.widget<TextField>(fields.at(6)).controller!.text, '12');
    expect(tester.widget<TextField>(fields.at(8)).controller!.text, isEmpty);
    expect(tester.widget<TextField>(fields.at(9)).controller!.text, isEmpty);
    expect(tester.widget<TextField>(fields.at(13)).controller!.text, '285000');
    expect(find.textContaining('직접 입력 필요'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'period averages load first and saved settings require a choice',
    (tester) async {
      const savedProfile = RestaurantForecastProfile(
        floors: [
          RestaurantFloorCapacity(
            label: 'Saved floor',
            tableCount: 7,
            serviceUnitsPerHour: 11,
          ),
        ],
        seatedToFirstServeMinutes: 9,
        diningMinutes: 50,
        paymentWaitMinutes: 4,
        cleanupMinutes: 8,
        kitchenUnitsPerHour: 20,
        checkerUnitsPerHour: 18,
        operatingMinutesPerDay: 660,
        operatingWeekdays: {1, 2, 3, 4, 5, 6, 7},
        averageTicketVnd: 275000,
      );
      final profileRepository = _MemoryProfileRepository()
        ..snapshot = RevenueForecastProfileSnapshot(
          storeId: '00000000-0000-0000-0000-000000000001',
          revision: 3,
          businessType: ForecastBusinessType.restaurant,
          settings: restaurantProfileToJson(savedProfile),
          effectiveFrom: DateTime.utc(2026, 9, 1),
        );
      await _pumpPanel(
        tester,
        type: ForecastBusinessType.restaurant,
        locale: const Locale('en'),
        width: 1024,
        profileRepository: profileRepository,
        defaultsRepository: _MemoryDefaultsRepository(
          _periodDefaults(
            savedProfile.copyWith(
              floors: const [
                RestaurantFloorCapacity(
                  label: 'Generated floor',
                  tableCount: 99,
                  serviceUnitsPerHour: 99,
                ),
              ],
            ),
            unavailable: const {},
          ),
        ),
      );

      expect(find.text('Revision 3'), findsOneWidget);
      expect(
        find.byKey(const Key('revenue_forecast_defaults_applied')),
        findsOneWidget,
      );
      final fields = find.byType(TextField);
      expect(fields, findsNWidgets(11));
      expect(
        tester.widget<TextField>(fields.first).controller!.text,
        'Generated floor',
      );
      expect(tester.widget<TextField>(fields.at(1)).controller!.text, '99');

      final applySaved = find.byKey(
        const Key('revenue_forecast_apply_saved_profile'),
      );
      await tester.ensureVisible(applySaved);
      await tester.tap(applySaved);
      await tester.pumpAndSettle();

      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        'Saved floor',
      );
      expect(
        find.byKey(const Key('revenue_forecast_apply_period_average')),
        findsOneWidget,
      );
      expect(tester.widget<TextField>(fields.at(1)).controller!.text, '7');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'restaurant forecast calculates and shows six improvement areas',
    (tester) async {
      String? savedName;
      Uint8List? savedBytes;
      await _pumpPanel(
        tester,
        type: ForecastBusinessType.restaurant,
        locale: const Locale('en'),
        width: 1024,
        saveExcelFile:
            ({required String name, required Uint8List bytes}) async {
              savedName = name;
              savedBytes = bytes;
            },
      );

      final fields = find.byType(TextField);
      expect(fields, findsNWidgets(11));
      final values = [
        'Ground',
        '20',
        '50',
        '10',
        '45',
        '5',
        '10',
        '50',
        '50',
        '720',
        '300,000',
      ];
      for (var index = 0; index < values.length; index++) {
        await tester.enterText(fields.at(index), values[index]);
      }
      await _selectAllOperatingWeekdays(
        tester,
        ForecastBusinessType.restaurant,
      );
      final calculate = find.byKey(const Key('revenue_forecast_calculate'));
      await tester.ensureVisible(calculate);
      await tester.tap(calculate);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('revenue_forecast_result')), findsOneWidget);
      expect(find.text('Reduce table reset time'), findsOneWidget);
      expect(find.text('Increase kitchen throughput'), findsOneWidget);
      expect(find.text('Increase checker throughput'), findsOneWidget);
      expect(find.text('Increase floor service throughput'), findsOneWidget);
      expect(find.text('Reduce payment waiting time'), findsOneWidget);
      expect(find.text('Extend operating time'), findsOneWidget);
      final save = find.byKey(const Key('revenue_forecast_save_profile'));
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(find.text('Settings saved'), findsOneWidget);
      expect(find.text('Revision 1'), findsOneWidget);
      final download = find.byKey(const Key('revenue_forecast_download'));
      await tester.ensureVisible(download);
      await tester.tap(download);
      await tester.pumpAndSettle();
      expect(savedName, startsWith('revenue_forecast_'));
      expect(savedBytes, isNotNull);
      expect(savedBytes, isNotEmpty);
      await tester.enterText(fields.at(10), '310,000');
      await tester.pump();
      expect(find.byKey(const Key('revenue_forecast_result')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Photo uses fixed policy and omits recommendations on mobile', (
    tester,
  ) async {
    await _pumpPanel(
      tester,
      type: ForecastBusinessType.photo,
      locale: const Locale('ko'),
      width: 390,
    );

    expect(find.textContaining('기기당 1회 8분'), findsOneWidget);
    expect(find.textContaining('85,000동'), findsOneWidget);
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '2');
    await tester.enterText(fields.at(1), '720');
    await tester.enterText(fields.at(2), '0');
    await _selectAllOperatingWeekdays(tester, ForecastBusinessType.photo);
    final calculate = find.byKey(const Key('revenue_forecast_calculate'));
    await tester.ensureVisible(calculate);
    await tester.tap(calculate);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('revenue_forecast_result')), findsOneWidget);
    expect(find.text('포토 예측에는 별도 개선 제안을 제공하지 않습니다.'), findsOneWidget);
    expect(find.text('테이블 정리시간 단축'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings remain usable at 320 pixels and 200 percent text', (
    tester,
  ) async {
    await _pumpPanel(
      tester,
      type: ForecastBusinessType.restaurant,
      locale: const Locale('vi'),
      width: 320,
      textScale: 2,
    );

    expect(find.text('Dự báo doanh thu'), findsOneWidget);
    expect(find.byKey(const Key('revenue_forecast_calculate')), findsOneWidget);
    final fields = find.byType(TextField);
    final values = [
      'Tầng trệt',
      '20',
      '50',
      '10',
      '45',
      '5',
      '10',
      '50',
      '50',
      '720',
      '300.000',
    ];
    for (var index = 0; index < values.length; index++) {
      await tester.enterText(fields.at(index), values[index]);
    }
    await _selectAllOperatingWeekdays(tester, ForecastBusinessType.restaurant);
    final calculate = find.byKey(const Key('revenue_forecast_calculate'));
    await tester.ensureVisible(calculate);
    await tester.tap(calculate);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('revenue_forecast_result')), findsOneWidget);
    final layoutError = tester.takeException();
    if (layoutError is FlutterError) {
      fail(layoutError.toStringDeep());
    }
    expect(layoutError, isNull);
  });

  testWidgets('late profile response does not overwrite an edited draft', (
    tester,
  ) async {
    final start = DateTime.utc(2026, 7, 1);
    final repository = _DelayedProfileRepository();
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            child: RevenueForecastPanel(
              storeId: '00000000-0000-0000-0000-000000000001',
              businessType: ForecastBusinessType.restaurant,
              trainingStart: start,
              trainingEnd: start.add(const Duration(days: 34)),
              observations: _observations(start, 35),
              canSaveProfile: true,
              profileRepository: repository,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final firstField = find.byType(TextField).first;
    await tester.enterText(firstField, 'My draft');

    const remoteProfile = RestaurantForecastProfile(
      floors: [
        RestaurantFloorCapacity(
          label: 'Remote floor',
          tableCount: 10,
          serviceUnitsPerHour: 20,
        ),
      ],
      seatedToFirstServeMinutes: 10,
      diningMinutes: 45,
      paymentWaitMinutes: 5,
      cleanupMinutes: 10,
      kitchenUnitsPerHour: 30,
      checkerUnitsPerHour: 30,
      operatingMinutesPerDay: 720,
      operatingWeekdays: {1, 2, 3, 4, 5, 6, 7},
      averageTicketVnd: 250000,
    );
    repository.completer.complete(
      RevenueForecastProfileSnapshot(
        storeId: '00000000-0000-0000-0000-000000000001',
        revision: 2,
        businessType: ForecastBusinessType.restaurant,
        settings: restaurantProfileToJson(remoteProfile),
        effectiveFrom: DateTime.utc(2026, 9, 1),
      ),
    );
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(firstField);
    expect(field.controller!.text, 'My draft');
    expect(find.text('Revision 2'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('runtime locale change preserves draft and calculated result', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1024, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      _LocaleSwitchHost(repository: _MemoryProfileRepository()),
    );
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    const values = [
      'Ground',
      '20',
      '50',
      '10',
      '45',
      '5',
      '10',
      '50',
      '50',
      '720',
      '300,000',
    ];
    for (var index = 0; index < values.length; index++) {
      await tester.enterText(fields.at(index), values[index]);
    }
    await _selectAllOperatingWeekdays(tester, ForecastBusinessType.restaurant);
    final calculate = find.byKey(const Key('revenue_forecast_calculate'));
    await tester.ensureVisible(calculate);
    await tester.tap(calculate);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('revenue_forecast_result')), findsOneWidget);

    final switcher = find.byKey(const Key('switch_forecast_locale'));
    await tester.ensureVisible(switcher);
    await tester.tap(switcher);
    await tester.pumpAndSettle();

    expect(find.text('매출 예측'), findsOneWidget);
    expect(find.byKey(const Key('revenue_forecast_result')), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      'Ground',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('profile save validates required operating weekdays locally', (
    tester,
  ) async {
    await _pumpPanel(
      tester,
      type: ForecastBusinessType.photo,
      locale: const Locale('en'),
      width: 390,
    );
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '1');
    await tester.enterText(fields.at(1), '720');
    await tester.enterText(fields.at(2), '0');

    final save = find.byKey(const Key('revenue_forecast_save_profile'));
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(
      find.text('Check every capacity setting and try again.'),
      findsOneWidget,
    );
    expect(find.text('Settings saved'), findsNothing);
  });
}
