import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late String migrationContent;

  setUpAll(() {
    final file = File(
      'supabase/migrations/20260610000001_fix_daily_closing_hcmc_window.sql',
    );
    expect(file.existsSync(), isTrue, reason: 'Migration file must exist');
    migrationContent = file.readAsStringSync();
  });

  group('create_daily_closing HCMC window fix', () {
    test('uses AT TIME ZONE for day_start', () {
      expect(
        migrationContent,
        contains("AT TIME ZONE 'Asia/Ho_Chi_Minh'"),
        reason: 'Must use explicit HCMC timezone conversion, not ::TIMESTAMPTZ',
      );
    });

    test('declares v_day_end upper bound', () {
      expect(
        migrationContent,
        contains('v_day_end'),
        reason: 'Must have an upper bound variable for the business day',
      );
    });

    test('uses v_day_end in orders query', () {
      final ordersUpperBound = RegExp(
        r'created_at\s*<\s*v_day_end',
        multiLine: true,
      );
      final matches = ordersUpperBound.allMatches(migrationContent).length;
      expect(
        matches,
        greaterThanOrEqualTo(4),
        reason:
            'All 4 metric queries (orders, items, revenue payments, service payments) must have upper bound',
      );
    });

    test('does not use the buggy ::TIMESTAMPTZ pattern in executable code', () {
      final executableLines = migrationContent
          .split('\n')
          .where((line) => !line.trimLeft().startsWith('--'))
          .join('\n');
      expect(
        executableLines,
        isNot(contains("v_closing_date::TIMESTAMPTZ")),
        reason: 'The original buggy pattern must not appear in executable code',
      );
    });

    test('historical audit query is included as comment', () {
      expect(
        migrationContent,
        contains('delta'),
        reason:
            'Historical impact query must be included (commented) for manual review',
      );
    });
  });

  group('get_admin_today_summary HCMC window fix', () {
    test('fixes the same boundary pattern', () {
      final todaySummarySection = migrationContent.substring(
        migrationContent.indexOf('get_admin_today_summary'),
      );
      expect(
        todaySummarySection,
        contains("AT TIME ZONE 'Asia/Ho_Chi_Minh'"),
        reason: 'get_admin_today_summary must also use HCMC timezone',
      );
    });

    test('declares v_today_end upper bound', () {
      final todaySummarySection = migrationContent.substring(
        migrationContent.indexOf('get_admin_today_summary'),
      );
      expect(
        todaySummarySection,
        contains('v_today_end'),
        reason: 'Must have upper bound for today summary queries',
      );
    });
  });
}
