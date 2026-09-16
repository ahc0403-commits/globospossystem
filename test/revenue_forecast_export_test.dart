import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/report/revenue_forecast/revenue_forecast_engine.dart';
import 'package:globos_pos_system/features/report/revenue_forecast/revenue_forecast_export.dart';
import 'package:globos_pos_system/features/report/revenue_forecast/revenue_forecast_profile_service.dart';

const _copy = RevenueForecastExportCopy(
  summarySheet: 'Summary',
  monthlySheet: 'Monthly',
  inputsSheet: 'Inputs',
  improvementsSheet: 'Improvements',
  forecastTitle: 'Revenue forecast',
  businessTypeLabel: 'Business type',
  businessType: 'Business type',
  trainingPeriod: 'Training period',
  forecastHorizon: 'Forecast horizon',
  modelQuality: 'Model quality',
  profileRevision: 'Profile revision',
  expectedRevenue: 'Expected revenue',
  demandRevenue: 'Demand revenue',
  capacityLimit: 'Capacity limit',
  completeMonth: 'Complete month',
  partialMonth: 'Partial month',
  extraRevenue: 'Extra revenue',
  nextBottleneck: 'Next bottleneck',
  notGuarantee: 'Planning estimate only',
  store: 'Store',
  status: 'Status',
  date: 'Date',
  generatedAt: 'Generated at',
  timezone: 'Timezone',
  field: 'Field',
  value: 'Value',
  current: 'Current',
  proposed: 'Proposed',
  servedUnits: 'Served units',
  actualRevenue: 'Actual revenue',
  dineInRevenue: 'Dine-in revenue',
  observedUnits: 'Observed units',
  firstReachedMonth: 'First reached month',
  maintainedForThreeMonths: 'Maintained for 3 months',
  monthlyTarget: 'Monthly target VND',
  localeLabel: 'Language',
  yes: 'Yes',
  no: 'No',
  goalStatuses: {
    ForecastGoalStatus.reached: 'Reached',
    ForecastGoalStatus.demandNotReached: 'Demand not reached',
    ForecastGoalStatus.capacityExceeded: 'Capacity exceeded',
    ForecastGoalStatus.insufficientEvidence: 'Insufficient evidence',
  },
  recommendationKinds: {
    ForecastRecommendationKind.tableTurnover: 'Table turnover',
    ForecastRecommendationKind.kitchen: 'Kitchen',
    ForecastRecommendationKind.checker: 'Checker',
    ForecastRecommendationKind.floorService: 'Floor service',
    ForecastRecommendationKind.nonDiningWait: 'Payment wait',
    ForecastRecommendationKind.operatingHours: 'Operating hours',
  },
  bottlenecks: {
    'demand': 'Demand',
    'kitchen': 'Kitchen',
    'checker': 'Checker',
    'table_turnover': 'Table turnover',
    'floor_service': 'Floor service',
    'photo_capacity': 'Photo capacity',
    'closed': 'Closed day',
  },
);

List<RevenueForecastObservation> _rows(DateTime start) => List.generate(
  35,
  (index) => RevenueForecastObservation(
    date: start.add(Duration(days: index)),
    revenueVnd: 2000000 + index * 100000,
    dineInRevenueVnd: 1400000 + index * 70000,
    units: 20 + index / 10,
  ),
);

void main() {
  final start = DateTime.utc(2026, 7, 1);
  final end = start.add(const Duration(days: 34));
  final forecastEnd = DateTime.utc(2026, 12, 31);
  final rows = _rows(start);

  test('restaurant workbook keeps numeric cells and improvement sheet', () {
    const profile = RestaurantForecastProfile(
      floors: [
        RestaurantFloorCapacity(
          label: '=Ground',
          tableCount: 20,
          serviceUnitsPerHour: 40,
        ),
      ],
      seatedToFirstServeMinutes: 10,
      diningMinutes: 45,
      paymentWaitMinutes: 5,
      cleanupMinutes: 10,
      kitchenUnitsPerHour: 50,
      checkerUnitsPerHour: 50,
      operatingMinutesPerDay: 720,
      operatingWeekdays: {1, 2, 3, 4, 5, 6, 7},
      averageTicketVnd: 300000,
    );
    final result = const RevenueForecastEngine().forecastRestaurant(
      observations: rows,
      trainingStart: start,
      trainingEnd: end,
      forecastEnd: forecastEnd,
      profile: profile,
    );
    final bytes = buildRevenueForecastWorkbook(
      RevenueForecastExportSnapshot(
        storeName: '=Injected',
        locale: 'en',
        generatedAt: DateTime.utc(2026, 9, 16),
        profileRevision: 3,
        result: result,
        observations: rows,
        settings: restaurantProfileToJson(profile),
        copy: _copy,
      ),
    );

    final workbook = Excel.decodeBytes(bytes);
    expect(
      workbook.tables.keys,
      containsAll(['Summary', 'Monthly', 'Inputs', 'Improvements']),
    );
    expect(
      workbook.tables['Summary']!.rows[1][1]!.value.toString(),
      "'=Injected",
    );
    expect(
      workbook.tables['Monthly']!.rows[1][1]!.value,
      anyOf(isA<DoubleCellValue>(), isA<IntCellValue>()),
    );
    expect(
      workbook.tables['Inputs']!.rows.any(
        (row) =>
            row.first?.value.toString().contains('floors[0].label') == true,
      ),
      isTrue,
    );
    expect(
      workbook.tables['Summary']!.rows.any(
        (row) =>
            row.first?.value.toString() == 'validation.rolling_origin_folds' &&
            row[1]?.value.toString() == '7',
      ),
      isTrue,
    );
  });

  test(
    'Photo workbook records fixed constants and has no improvement sheet',
    () {
      const profile = PhotoForecastProfile(
        machineCount: 2,
        operatingMinutesPerDay: 720,
        operatingWeekdays: {1, 2, 3, 4, 5, 6, 7},
        freeServiceSessionsPerDay: 4,
      );
      final result = const RevenueForecastEngine().forecastPhoto(
        observations: rows,
        trainingStart: start,
        trainingEnd: end,
        forecastEnd: forecastEnd,
        profile: profile,
      );
      final bytes = buildRevenueForecastWorkbook(
        RevenueForecastExportSnapshot(
          storeName: 'Photo store',
          locale: 'vi',
          generatedAt: DateTime.utc(2026, 9, 16),
          profileRevision: 1,
          result: result,
          observations: rows,
          settings: photoProfileToJson(profile),
          copy: _copy,
        ),
      );

      final workbook = Excel.decodeBytes(bytes);
      expect(
        workbook.tables.keys,
        containsAll(['Summary', 'Monthly', 'Inputs']),
      );
      expect(workbook.tables.keys, isNot(contains('Improvements')));
      final inputRows = workbook.tables['Inputs']!.rows;
      expect(
        inputRows.any(
          (row) =>
              row.first?.value.toString() == 'session_minutes_fixed' &&
              row[1]?.value.toString() == '8',
        ),
        isTrue,
      );
      expect(
        inputRows.any(
          (row) =>
              row.first?.value.toString() ==
                  'revenue_per_paid_session_vnd_fixed' &&
              double.tryParse(row[1]?.value.toString() ?? '') == 85000,
        ),
        isTrue,
      );
    },
  );
}
