import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/admin/providers/daily_closing_provider.dart';

void main() {
  test('deposit total uses counted cash minus the opening cash float', () {
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

    expect(record.depositTotal, 2512000);
  });

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
