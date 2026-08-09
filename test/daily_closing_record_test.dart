import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/admin/providers/daily_closing_provider.dart';

void main() {
  test('deposit total uses counted cash minus cash sales and variance', () {
    final record = DailyClosingRecord(
      id: 'closing-id',
      closingDate: '2026-08-09',
      closedByName: 'Manager',
      ordersTotal: 4,
      ordersCompleted: 4,
      ordersCancelled: 0,
      itemsCancelled: 0,
      paymentsCount: 4,
      paymentsTotal: 12000000,
      paymentsCash: 3000000,
      paymentsCard: 9000000,
      paymentsPay: 0,
      paymentsBankTransfer: 0,
      openingCashAmount: 5000000,
      expectedCashAmount: 8000000,
      countedCashAmount: 8100000,
      cashVariance: 100000,
      serviceCount: 0,
      serviceTotal: 0,
      lowStockCount: 0,
      closeSource: 'manual',
      createdAt: DateTime(2026, 8, 9),
    );

    expect(record.depositTotal, 5000000);
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
}
