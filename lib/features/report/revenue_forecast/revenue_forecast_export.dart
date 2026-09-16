import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:intl/intl.dart';

import 'revenue_forecast_engine.dart';

class RevenueForecastExportCopy {
  const RevenueForecastExportCopy({
    required this.summarySheet,
    required this.monthlySheet,
    required this.inputsSheet,
    required this.improvementsSheet,
    required this.forecastTitle,
    required this.businessType,
    required this.businessTypeLabel,
    required this.trainingPeriod,
    required this.forecastHorizon,
    required this.modelQuality,
    required this.profileRevision,
    required this.expectedRevenue,
    required this.demandRevenue,
    required this.capacityLimit,
    required this.completeMonth,
    required this.partialMonth,
    required this.extraRevenue,
    required this.nextBottleneck,
    required this.notGuarantee,
    required this.store,
    required this.status,
    required this.date,
    required this.generatedAt,
    required this.timezone,
    required this.field,
    required this.value,
    required this.current,
    required this.proposed,
    required this.servedUnits,
    required this.actualRevenue,
    required this.dineInRevenue,
    required this.observedUnits,
    required this.firstReachedMonth,
    required this.maintainedForThreeMonths,
    required this.monthlyTarget,
    required this.localeLabel,
    required this.yes,
    required this.no,
    required this.goalStatuses,
    required this.recommendationKinds,
    required this.bottlenecks,
  });

  final String summarySheet;
  final String monthlySheet;
  final String inputsSheet;
  final String improvementsSheet;
  final String forecastTitle;
  final String businessType;
  final String businessTypeLabel;
  final String trainingPeriod;
  final String forecastHorizon;
  final String modelQuality;
  final String profileRevision;
  final String expectedRevenue;
  final String demandRevenue;
  final String capacityLimit;
  final String completeMonth;
  final String partialMonth;
  final String extraRevenue;
  final String nextBottleneck;
  final String notGuarantee;
  final String store;
  final String status;
  final String date;
  final String generatedAt;
  final String timezone;
  final String field;
  final String value;
  final String current;
  final String proposed;
  final String servedUnits;
  final String actualRevenue;
  final String dineInRevenue;
  final String observedUnits;
  final String firstReachedMonth;
  final String maintainedForThreeMonths;
  final String monthlyTarget;
  final String localeLabel;
  final String yes;
  final String no;
  final Map<ForecastGoalStatus, String> goalStatuses;
  final Map<ForecastRecommendationKind, String> recommendationKinds;
  final Map<String, String> bottlenecks;
}

class RevenueForecastExportSnapshot {
  const RevenueForecastExportSnapshot({
    required this.storeName,
    required this.locale,
    required this.generatedAt,
    required this.profileRevision,
    required this.result,
    required this.observations,
    required this.settings,
    required this.copy,
  });

  final String storeName;
  final String locale;
  final DateTime generatedAt;
  final int profileRevision;
  final RevenueForecastResult result;
  final List<RevenueForecastObservation> observations;
  final Map<String, dynamic> settings;
  final RevenueForecastExportCopy copy;
}

Uint8List buildRevenueForecastWorkbook(RevenueForecastExportSnapshot snapshot) {
  final workbook = Excel.createExcel();
  final summaryName = _sheetName(snapshot.copy.summarySheet, 'Summary');
  workbook.rename('Sheet1', summaryName);
  final summary = workbook[summaryName];
  final dateFormat = DateFormat('yyyy-MM-dd');

  summary.appendRow([TextCellValue(_safeText(snapshot.copy.forecastTitle))]);
  summary.appendRow([
    TextCellValue(snapshot.copy.store),
    TextCellValue(_safeText(snapshot.storeName)),
  ]);
  summary.appendRow([
    TextCellValue(snapshot.copy.businessTypeLabel),
    TextCellValue(snapshot.copy.businessType),
  ]);
  summary.appendRow([
    TextCellValue(snapshot.copy.trainingPeriod),
    TextCellValue(
      '${dateFormat.format(snapshot.result.trainingStart)} – '
      '${dateFormat.format(snapshot.result.trainingEnd)}',
    ),
  ]);
  summary.appendRow([
    TextCellValue(snapshot.copy.forecastHorizon),
    TextCellValue(
      '${dateFormat.format(snapshot.result.days.first.date)} – '
      '${dateFormat.format(snapshot.result.days.last.date)}',
    ),
  ]);
  summary.appendRow([
    TextCellValue(snapshot.copy.modelQuality),
    DoubleCellValue(snapshot.result.regression.rSquared),
  ]);
  const coefficientLabels = [
    'coefficient.intercept',
    'coefficient.daily_trend',
    'coefficient.tuesday',
    'coefficient.wednesday',
    'coefficient.thursday',
    'coefficient.friday',
    'coefficient.saturday',
    'coefficient.sunday',
  ];
  for (var index = 0; index < coefficientLabels.length; index++) {
    summary.appendRow([
      TextCellValue(coefficientLabels[index]),
      DoubleCellValue(snapshot.result.regression.coefficients[index]),
    ]);
  }
  summary.appendRow([
    TextCellValue('regression.center_day'),
    DoubleCellValue(snapshot.result.regression.centerDay),
  ]);
  summary.appendRow([
    TextCellValue('regression.rmse'),
    DoubleCellValue(snapshot.result.regression.rmse),
  ]);
  summary.appendRow([
    TextCellValue('validation.rolling_origin_folds'),
    IntCellValue(snapshot.result.backtest.foldCount),
  ]);
  for (final metric in <(String, double?)>[
    ('validation.mae', snapshot.result.backtest.mae),
    ('validation.rmse', snapshot.result.backtest.rmse),
    ('validation.wape', snapshot.result.backtest.wape),
    ('validation.bias', snapshot.result.backtest.bias),
    (
      'validation.same_weekday_baseline_mae',
      snapshot.result.backtest.weekdayBaselineMae,
    ),
  ]) {
    summary.appendRow([
      TextCellValue(metric.$1),
      metric.$2 == null ? TextCellValue('') : DoubleCellValue(metric.$2!),
    ]);
  }
  summary.appendRow([
    TextCellValue(snapshot.copy.profileRevision),
    IntCellValue(snapshot.profileRevision),
  ]);
  summary.appendRow([
    TextCellValue(snapshot.copy.localeLabel),
    TextCellValue(snapshot.locale),
  ]);
  summary.appendRow([
    TextCellValue(snapshot.copy.timezone),
    TextCellValue('Asia/Ho_Chi_Minh'),
  ]);
  summary.appendRow([
    TextCellValue(snapshot.copy.generatedAt),
    TextCellValue(snapshot.generatedAt.toIso8601String()),
  ]);
  summary.appendRow([TextCellValue(_safeText(snapshot.copy.notGuarantee))]);
  summary.appendRow([TextCellValue('')]);
  summary.appendRow([
    TextCellValue(snapshot.copy.monthlyTarget),
    TextCellValue(snapshot.copy.status),
    TextCellValue(snapshot.copy.firstReachedMonth),
    TextCellValue(snapshot.copy.maintainedForThreeMonths),
  ]);
  for (final goal in snapshot.result.goals) {
    summary.appendRow([
      DoubleCellValue(goal.targetVnd),
      TextCellValue(
        snapshot.copy.goalStatuses[goal.status] ?? goal.status.name,
      ),
      TextCellValue(
        goal.firstReachedMonth == null
            ? ''
            : DateFormat('yyyy-MM').format(goal.firstReachedMonth!),
      ),
      TextCellValue(
        goal.maintainedForThreeMonths ? snapshot.copy.yes : snapshot.copy.no,
      ),
    ]);
  }

  final monthlyName = _uniqueSheetName(
    workbook,
    _sheetName(snapshot.copy.monthlySheet, 'Monthly'),
  );
  final monthly = workbook[monthlyName];
  monthly.appendRow([
    TextCellValue(snapshot.copy.monthlySheet),
    TextCellValue(snapshot.copy.expectedRevenue),
    TextCellValue(snapshot.copy.demandRevenue),
    TextCellValue(snapshot.copy.capacityLimit),
    TextCellValue(snapshot.copy.status),
    TextCellValue(snapshot.copy.servedUnits),
  ]);
  for (final month in snapshot.result.months) {
    monthly.appendRow([
      TextCellValue(DateFormat('yyyy-MM').format(month.month)),
      DoubleCellValue(month.forecastRevenueVnd),
      DoubleCellValue(month.demandRevenueVnd),
      DoubleCellValue(month.capacityRevenueVnd),
      TextCellValue(
        month.isCompleteMonth
            ? snapshot.copy.completeMonth
            : snapshot.copy.partialMonth,
      ),
      DoubleCellValue(month.servedUnits),
    ]);
  }

  monthly.appendRow([TextCellValue('')]);
  monthly.appendRow([
    TextCellValue(snapshot.copy.date),
    TextCellValue(snapshot.copy.actualRevenue),
    TextCellValue(snapshot.copy.dineInRevenue),
    TextCellValue(snapshot.copy.observedUnits),
  ]);
  for (final observation in snapshot.observations) {
    monthly.appendRow([
      TextCellValue(dateFormat.format(observation.date)),
      DoubleCellValue(observation.revenueVnd),
      DoubleCellValue(observation.dineInRevenueVnd),
      observation.units == null
          ? TextCellValue('')
          : DoubleCellValue(observation.units!),
    ]);
  }

  final inputsName = _uniqueSheetName(
    workbook,
    _sheetName(snapshot.copy.inputsSheet, 'Inputs'),
  );
  final inputs = workbook[inputsName];
  inputs.appendRow([
    TextCellValue(snapshot.copy.field),
    TextCellValue(snapshot.copy.value),
  ]);
  for (final entry in _flattenSettings(snapshot.settings)) {
    inputs.appendRow([
      TextCellValue(_safeText(entry.$1)),
      switch (entry.$2) {
        int value => IntCellValue(value),
        double value => DoubleCellValue(value),
        final value => TextCellValue(_safeText(value.toString())),
      },
    ]);
  }
  if (snapshot.result.businessType == ForecastBusinessType.photo) {
    inputs.appendRow([
      TextCellValue('session_minutes_fixed'),
      IntCellValue(photoSessionMinutes),
    ]);
    inputs.appendRow([
      TextCellValue('revenue_per_paid_session_vnd_fixed'),
      DoubleCellValue(photoRevenuePerPaidSessionVnd),
    ]);
  } else {
    final improvementsName = _uniqueSheetName(
      workbook,
      _sheetName(snapshot.copy.improvementsSheet, 'Improvements'),
    );
    final improvements = workbook[improvementsName];
    improvements.appendRow([
      TextCellValue(snapshot.copy.improvementsSheet),
      TextCellValue(snapshot.copy.current),
      TextCellValue(snapshot.copy.proposed),
      TextCellValue(snapshot.copy.extraRevenue),
      TextCellValue(snapshot.copy.servedUnits),
      TextCellValue(snapshot.copy.nextBottleneck),
    ]);
    for (final recommendation in snapshot.result.recommendations) {
      improvements.appendRow([
        TextCellValue(
          snapshot.copy.recommendationKinds[recommendation.kind] ??
              recommendation.kind.name,
        ),
        DoubleCellValue(recommendation.currentValue),
        DoubleCellValue(recommendation.proposedValue),
        DoubleCellValue(recommendation.extraRevenueVnd),
        DoubleCellValue(recommendation.extraServedUnits),
        TextCellValue(
          snapshot.copy.bottlenecks[recommendation.nextBottleneck] ??
              recommendation.nextBottleneck,
        ),
      ]);
    }
  }

  final bytes = workbook.encode();
  if (bytes == null) throw StateError('FORECAST_EXPORT_ENCODING_FAILED');
  return Uint8List.fromList(bytes);
}

List<(String, dynamic)> _flattenSettings(
  Map<String, dynamic> settings, [
  String prefix = '',
]) {
  final result = <(String, dynamic)>[];
  for (final entry in settings.entries) {
    final key = prefix.isEmpty ? entry.key : '$prefix.${entry.key}';
    final value = entry.value;
    if (value is Map) {
      result.addAll(_flattenSettings(Map<String, dynamic>.from(value), key));
    } else if (value is List) {
      for (var index = 0; index < value.length; index++) {
        final item = value[index];
        if (item is Map) {
          result.addAll(
            _flattenSettings(Map<String, dynamic>.from(item), '$key[$index]'),
          );
        } else {
          result.add(('$key[$index]', item));
        }
      }
    } else {
      result.add((key, value));
    }
  }
  return result;
}

String _sheetName(String requested, String fallback) {
  final cleaned = requested.replaceAll(RegExp(r"[\\/*?:\[\]]"), ' ').trim();
  final safe = cleaned.isEmpty ? fallback : cleaned;
  return safe.length <= 31 ? safe : safe.substring(0, 31);
}

String _uniqueSheetName(Excel workbook, String requested) {
  if (!workbook.tables.containsKey(requested)) return requested;
  for (var suffix = 2; suffix < 100; suffix++) {
    final suffixText = ' $suffix';
    final baseLength = 31 - suffixText.length;
    final candidate =
        '${requested.substring(0, requested.length.clamp(0, baseLength))}$suffixText';
    if (!workbook.tables.containsKey(candidate)) return candidate;
  }
  throw StateError('FORECAST_EXPORT_SHEET_NAME_EXHAUSTED');
}

String _safeText(String value) {
  final trimmedLeft = value.trimLeft();
  if (trimmedLeft.startsWith('=') ||
      trimmedLeft.startsWith('+') ||
      trimmedLeft.startsWith('-') ||
      trimmedLeft.startsWith('@')) {
    return "'$value";
  }
  return value;
}
