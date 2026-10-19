import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/admin/providers/daily_closing_provider.dart';

void main() {
  test(
    'deposit total uses cash sales and preserves the separate cash count',
    () {
      final record = DailyClosingRecord(
        id: 'closing-id',
        closingDate: '2026-08-09',
        closedByName: 'Manager',
        ordersTotal: 4,
        ordersCompleted: 4,
        ordersCancelled: 0,
        itemsCancelled: 0,
        paymentsCount: 4,
        paymentsTotal: 5617056,
        paymentsCash: 2035496,
        paymentsCard: 0,
        paymentsPay: 0,
        paymentsBankTransfer: 3581560,
        deliveryCashPayout: 0,
        openingCashAmount: 5000000,
        expectedCashAmount: 7035496,
        countedCashAmount: 7512000,
        cashVariance: 476504,
        serviceCount: 0,
        serviceTotal: 0,
        lowStockCount: 0,
        closeSource: 'manual',
        createdAt: DateTime(2026, 8, 9),
      );

      expect(record.depositTotal, 2035496);
      expect(record.countedDepositTotal, 2512000);
    },
  );

  test(
    'closing deposit preserves each dong instead of using a higher count',
    () {
      final record = DailyClosingRecord.fromJson({
        'closing_date': '2026-10-15',
        'close_source': 'manual',
        'payments_cash': 1622160,
        'opening_cash_amount': 5000000,
        'counted_cash_amount': 6623000,
        'expected_cash_amount': 6622160,
        'cash_variance': 840,
      });
      expect(record.depositTotal, 1622160);
      expect(record.confirmedDeposit, 1622160);
      expect(record.countedDepositTotal, 1623000);
      expect(record.cashVariance, 840);
      expect(record.depositNeedsReview, isTrue);
    },
  );

  test(
    'closing deposit reconciles refunds and cash movements exactly once',
    () {
      final record = DailyClosingRecord.fromJson({
        'close_source': 'manual',
        'payments_cash': 2000007,
        'direct_order_cash_refunds': 100001,
        'delivery_cash_paid': 150003,
        'delivery_cash_recovered': 50002,
        'opening_cash_amount': 5000000,
        'counted_cash_amount': 6750000,
        'cash_variance': -50005,
      });
      expect(record.depositTotal, 1800005);
      expect(record.countedDepositTotal, 1750000);
      expect(record.cashVariance, -50005);
    },
  );

  test('deposit total remains zero until the date is closed', () {
    final record = DailyClosingRecord(
      id: '',
      closingDate: '2026-08-09',
      closedByName: '',
      ordersTotal: 4,
      ordersCompleted: 4,
      ordersCancelled: 0,
      itemsCancelled: 0,
      paymentsCount: 4,
      paymentsTotal: 3000000,
      paymentsCash: 3000000,
      paymentsCard: 0,
      paymentsPay: 0,
      paymentsBankTransfer: 3000000,
      deliveryCashPayout: 0,
      openingCashAmount: 0,
      expectedCashAmount: 0,
      countedCashAmount: 0,
      cashVariance: 0,
      serviceCount: 0,
      serviceTotal: 0,
      lowStockCount: 0,
      closeSource: null,
      createdAt: DateTime(2026, 8, 9),
    );

    expect(record.depositTotal, 0);
  });

  test('record keeps immutable snapshot and live ledger totals separate', () {
    final record = DailyClosingRecord.fromJson({
      'closing_id': 'closing-id',
      'closing_date': '2026-09-16',
      'closed_by_name': 'Manager',
      'payments_total': 720360,
      'payments_cash': 0,
      'payments_card': 0,
      'payments_pay': 0,
      'payments_bank_transfer': 720360,
      'snapshot_payments_total': 720360,
      'ledger_payments_count': 34,
      'ledger_payments_total': 5523660,
      'ledger_payments_cash': 1391040,
      'ledger_payments_card': 0,
      'ledger_payments_pay': 0,
      'ledger_payments_bank_transfer': 4132620,
      'reconciliation_delta': 4803300,
      'ledger_as_of': '2026-09-16T08:30:00Z',
      'close_source': 'manual',
      'counted_cash_amount': 6391040,
      'opening_cash_amount': 5000000,
      'created_at': '2026-09-16T05:00:00Z',
    });

    expect(record.paymentsTotal, 720360);
    expect(record.snapshotPaymentsTotal, 720360);
    expect(record.ledgerPaymentsCount, 34);
    expect(record.ledgerPaymentsTotal, 5523660);
    expect(record.ledgerPaymentsCash, 1391040);
    expect(record.ledgerPaymentsBankTransfer, 4132620);
    expect(record.reconciliationDelta, 4803300);
    expect(record.isClosed, isTrue);
  });
}
