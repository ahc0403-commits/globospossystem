import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/payments/cash_deposit.dart';
import 'package:globos_pos_system/features/restaurant_sales_export/daily_sales_summary.dart';
import 'package:globos_pos_system/features/restaurant_sales_export/daily_sales_report_service.dart';
import 'package:globos_pos_system/features/admin/providers/daily_closing_provider.dart';
import 'daily_sales_report_service_test.dart' as fixtures;

void main() {
  test(
    'accepted deposit example uses counted cash, never the bank-transfer portion',
    () {
      final row = fixtures.row()
        ..addAll({
          'photo_gross': 10000000,
          'restaurant_bank_transfer': 3000000,
          'restaurant_cash': 2000000,
          'bunsik_cash': 2000000,
          'bunsik_closed_deposit': 1750000,
          'bunsik_expected_deposit': 1800000,
          'bunsik_variance': -50000,
          'bunsik_variance_store_count': 1,
        });
      final s = DailySalesSummary.fromJson('2026-10-12', row);
      expect(
        expectedCashBalance(
          openingCash: 5000000,
          cashSales: 2000000,
          cashRefunds: 100000,
          cashPaid: 150000,
          cashRecovered: 50000,
        ),
        6800000,
      );
      expect(s.cashDeposit, 1750000);
      expect(s.nextDeposit, 11750000);
      expect(s.restaurantBankTransfer, 3000000);
      expect(s.cashNeedsReview, isTrue);
      expect(s.depositConfirmed, isTrue);
      expect(s.depositDate, '2026-10-13');
    },
  );
  test('Photo missing cannot hide a counted cash deposit', () {
    final s = DailySalesSummary.fromJson(
      '2026-10-12',
      fixtures.row()..['photo_complete'] = false,
    );
    expect(s.photoDeposit, isNull);
    expect(s.cashDeposit, 200000);
    expect(s.nextDeposit, isNull);
  });
  test('partial, automatic and shortfall cash never become confirmed zero', () {
    for (final fields in [
      {'bunsik_store_count': 2, 'bunsik_closed_store_count': 1},
      {'bunsik_closed_store_count': 0, 'bunsik_closed_deposit': null},
      {'bunsik_shortfall_store_count': 1, 'bunsik_closed_deposit': -1000000},
    ]) {
      final s = DailySalesSummary.fromJson(
        '2026-10-12',
        fixtures.row()..addAll(fields),
      );
      expect(s.cashDeposit, isNull);
      expect(s.nextDeposit, isNull);
    }
  });
  test(
    'registered zero and a legal entity without Bunsik are explicitly zero',
    () {
      final s = DailySalesSummary.fromJson(
        '2026-10-12',
        fixtures.row()..addAll({
          'photo_gross': 0,
          'bunsik_store_count': 0,
          'bunsik_closed_store_count': 0,
          'bunsik_closed_deposit': 0,
          'bunsik_stores': <dynamic>[],
        }),
      );
      expect(s.photoDeposit, 0);
      expect(s.cashDeposit, 0);
      expect(s.nextDeposit, 0);
    },
  );
  test('legacy response lacking new breakdown remains unconfirmed', () {
    final row = fixtures.row()..removeWhere((k, _) => k.startsWith('bunsik_'));
    final s = DailySalesSummary.fromJson('2026-10-12', row);
    expect(s.cashDeposit, isNull);
    expect(s.nextDeposit, isNull);
  });
  test('civil next day is independent of timezone and year rollover', () {
    expect(nextDepositDate('2026-12-31'), '2027-01-01');
    expect(nextDepositDate('2028-02-28'), '2028-02-29');
  });
  test('manual closing with missing counted cash is invalid, not zero', () {
    expect(
      () => DailyClosingRecord.fromJson({
        'close_source': 'manual',
        'opening_cash_amount': 5000000,
      }),
      throwsFormatException,
    );
  });
  test(
    'closing review includes cash ledger changes even with unchanged total',
    () {
      final record = DailyClosingRecord.fromJson({
        'closing_date': '2026-10-12',
        'close_source': 'manual',
        'counted_cash_amount': 6750000,
        'opening_cash_amount': 5000000,
        'cash_variance': 0,
        'reconciliation_delta': 0,
        'cash_ledger_changed': true,
      });
      expect(record.confirmedDeposit, 1750000);
      expect(record.depositNeedsReview, isTrue);
    },
  );
  test(
    'summary shares requests, expires in 30s, and invalidates the selected day',
    () async {
      var now = DateTime.utc(2026, 10, 12);
      var calls = 0;
      final pending = Completer<dynamic>();
      final service = DailySalesReportService(
        now: () => now,
        rpc: (name, p) async {
          calls++;
          if (calls == 1) return pending.future;
          return {
            'business_date': p['p_business_date'],
            'entities': [fixtures.row()],
          };
        },
      );
      final a = service.summaries('2026-10-12'),
          b = service.summaries('2026-10-12');
      expect(calls, 1);
      pending.complete({
        'business_date': '2026-10-12',
        'entities': [fixtures.row()],
      });
      await Future.wait([a, b]);
      await service.summaries('2026-10-12');
      expect(calls, 1);
      now = now.add(const Duration(seconds: 31));
      await service.summaries('2026-10-12');
      expect(calls, 2);
      await service.summaries('2026-10-11');
      service.invalidateSummary('2026-10-12');
      await service.summaries('2026-10-11');
      expect(calls, 3);
      await service.summaries('2026-10-12');
      expect(calls, 4);
    },
  );
  test('session switch cannot reuse another actor summary', () async {
    var session = 'actor-A', calls = 0;
    final service = DailySalesReportService(
      sessionKey: () => session,
      rpc: (name, p) async {
        calls++;
        return {
          'business_date': p['p_business_date'],
          'entities': [fixtures.row()],
        };
      },
    );
    await service.summaries('2026-10-12');
    session = 'actor-B';
    await service.summaries('2026-10-12');
    expect(calls, 2);
  });
  test(
    'deferred metadata is loaded only for export and pins page versions',
    () async {
      final requests = <String>[];
      var pageRevision = 'v3-current';
      final initial = fixtures.row()
        ..addAll({
          'restaurant_receipt_count': 1,
          'restaurant_gross': 10800,
          'photo_receipt_count': 0,
          'photo_gross': 0,
          'mapping_revision': 7,
          'source_revision': null,
          'export_metadata_deferred': true,
        });
      final service = DailySalesReportService(
        rpc: (name, p) async {
          requests.add(name);
          if (name == 'get_pos_daily_sales_summary') {
            expect(p['p_include_export_metadata'], isTrue);
            return {
              'business_date': p['p_business_date'],
              'entities': [
                {
                  ...initial,
                  'export_metadata_deferred': false,
                  'source_revision': 'v3-current',
                },
              ],
            };
          }
          return {
            'business_date': p['p_business_date'],
            'tax_entity_id': 'entity',
            'source_system': 'restaurant_pos',
            'mapping_revision': 7,
            'source_revision': pageRevision,
            'rows': [fixtures.receipt(1)],
          };
        },
      );
      final summary = DailySalesSummary.fromJson('2026-10-08', initial);
      expect((await service.loadExport(summary)).grossSales, 10800);
      expect(requests, [
        'get_pos_daily_sales_summary',
        'get_pos_daily_sales_export_page',
      ]);
      pageRevision = 'v3-changed-during-export';
      await expectLater(service.loadExport(summary), throwsFormatException);
    },
  );
  test('bank detail from a logged-out session is discarded', () async {
    var session = 'A';
    final pending = Completer<dynamic>();
    final service = DailySalesReportService(
      sessionKey: () => session,
      rpc: (_, p) => pending.future,
    );
    final result = service.bankTransfers(
      fromDate: '2026-10-12',
      toDate: '2026-10-12',
      storeId: 'store',
    );
    session = 'B';
    pending.complete({
      'from_date': '2026-10-12',
      'to_date': '2026-10-12',
      'store_id': 'store',
      'tax_entity_id': null,
      'rows': [],
      'has_more': false,
    });
    await expectLater(result, throwsFormatException);
  });
  test(
    'transfer page rejects a foreign scope or nonadvancing cursor',
    () async {
      final service = DailySalesReportService(
        rpc: (name, p) async => {
          'from_date': p['p_from_date'],
          'to_date': p['p_to_date'],
          'tax_entity_id': p['p_tax_entity_id'],
          'store_id': p['p_store_id'],
          'has_more': false,
          'rows': [
            {
              'store_id': 'other',
              'store_name': 'Other',
              'amount': 100,
              'created_at': '2026-10-12T00:00:00Z',
              'payment_id': 'same',
            },
          ],
        },
      );
      await expectLater(
        service.bankTransfers(
          fromDate: '2026-10-12',
          toDate: '2026-10-12',
          storeId: 'own',
        ),
        throwsFormatException,
      );
      await expectLater(
        service.bankTransfers(
          fromDate: '2026-10-12',
          toDate: '2026-10-12',
          taxEntityId: 'entity',
          afterTime: '2026-10-12T00:00:00Z',
          afterId: 'same',
        ),
        throwsFormatException,
      );
    },
  );
}
