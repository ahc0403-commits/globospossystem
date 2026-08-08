import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/report/report_provider.dart';

void main() {
  test('production ledger keeps bank transfer separate from card', () {
    final payments = <Map<String, dynamic>>[
      {'amount': 55566, 'method': 'CASH'},
      {'amount': 55566, 'method': 'OTHER'},
      {'amount': 50896, 'method': 'CASH'},
      {'amount': 50896, 'method': 'OTHER'},
      {'amount': 574512, 'method': 'BANKTRANSFER'},
      {'amount': 526128, 'method': 'BANKTRANSFER'},
      {'amount': 243164, 'method': 'CASH'},
      {'amount': 258552, 'method': 'BANKTRANSFER'},
      {'amount': 197316, 'method': 'CASH'},
      {'amount': 189976, 'method': 'CASH'},
      {'amount': 222484, 'method': 'BANKTRANSFER'},
      {'amount': 185976, 'method': 'CASH'},
      {'amount': 147420, 'method': 'BANKTRANSFER'},
      {'amount': 95256, 'method': 'BANKTRANSFER'},
      {'amount': 59724, 'method': 'BANKTRANSFER'},
      {'amount': 373464, 'method': 'BANKTRANSFER'},
      {'amount': 586292, 'method': 'BANKTRANSFER'},
      {'amount': 319032, 'method': 'CASH'},
    ];

    final totals = aggregatePaymentMethodTotals(payments);

    expect(totals.cash, 1241926);
    expect(totals.card, 0);
    expect(totals.bankTransfer, 2843832);
    expect(totals.ePay, 106462);
    expect(totals.total, 4192220);
  });

  test('corrected ledger separates received money from sales allocation', () {
    final payments = <Map<String, dynamic>>[
      {'amount': 55500, 'amount_portion': 55566, 'method': 'BANKTRANSFER'},
      {'amount': 55500, 'amount_portion': 55566, 'method': 'BANKTRANSFER'},
      {'amount': 50896, 'amount_portion': 50896, 'method': 'BANKTRANSFER'},
      {'amount': 50896, 'amount_portion': 50896, 'method': 'BANKTRANSFER'},
      {'amount': 574512, 'amount_portion': 574512, 'method': 'CASH'},
      {'amount': 526128, 'amount_portion': 526128, 'method': 'BANKTRANSFER'},
      {'amount': 243164, 'amount_portion': 243164, 'method': 'CASH'},
      {'amount': 259000, 'amount_portion': 258552, 'method': 'BANKTRANSFER'},
      {'amount': 197316, 'amount_portion': 197316, 'method': 'CASH'},
      {'amount': 189976, 'amount_portion': 189976, 'method': 'CASH'},
      {'amount': 222484, 'amount_portion': 222484, 'method': 'BANKTRANSFER'},
      {'amount': 185976, 'amount_portion': 185976, 'method': 'CASH'},
      {'amount': 147420, 'amount_portion': 147420, 'method': 'BANKTRANSFER'},
      {'amount': 88200, 'amount_portion': 88200, 'method': 'BANKTRANSFER'},
      {'amount': 59698, 'amount_portion': 59724, 'method': 'BANKTRANSFER'},
      {'amount': 373302, 'amount_portion': 373464, 'method': 'BANKTRANSFER'},
      {'amount': 587000, 'amount_portion': 586292, 'method': 'BANKTRANSFER'},
      {'amount': 319032, 'amount_portion': 319032, 'method': 'CASH'},
      {'amount': 103284, 'amount_portion': 103284, 'method': 'BANKTRANSFER'},
      {'amount': 242140, 'amount_portion': 242140, 'method': 'BANKTRANSFER'},
    ];

    final totals = aggregatePaymentMethodTotals(payments);
    final salesTotal = aggregateRevenueSalesTotal(payments);

    expect(totals.cash, 1709976);
    expect(totals.card, 0);
    expect(totals.bankTransfer, 2821448);
    expect(totals.ePay, 0);
    expect(totals.total, 4531424);
    expect(salesTotal, 4530588);
    expect(totals.total - salesTotal, 836);
  });

  test('paid order count de-duplicates split payment rows', () {
    final payments = <Map<String, dynamic>>[
      {'id': 'payment-1', 'order_id': 'order-1'},
      {'id': 'payment-2', 'order_id': 'order-1'},
      {'id': 'payment-3', 'order_id': 'order-2'},
      {'id': 'payment-4', 'order_id': null},
    ];

    expect(countPaidRevenueOrders(payments), 3);
  });

  test('one-time correction is guarded and excluded from auto migrations', () {
    const path =
        'scripts/data_corrections/20260808_binh_thanh_payment_report.sql';
    final sql = File(path).readAsStringSync();

    expect(path, isNot(startsWith('supabase/migrations/')));
    expect(sql, contains('begin;'));
    expect(sql, contains('commit;'));
    expect(sql, contains('expected 10 exact payment rows'));
    expect(sql, contains('manual tax review required'));
    expect(sql, contains("amount = 88200"));
    expect(sql, contains("method = 'BANKTRANSFER'"));
    expect(sql, contains("method = 'CASH'"));
    expect(sql, contains('bank_statement_total <> 2476024'));
    expect(sql, contains('bank_sales_total <> 2475188'));
  });
}
