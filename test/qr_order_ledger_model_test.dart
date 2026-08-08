import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/payment/payment_provider.dart';

void main() {
  test('QR order ledger parses immutable batch snapshots', () {
    final batch = QrOrderLedgerBatch.fromJson({
      'batch_no': '2',
      'created_at': '2026-08-08T10:30:00+07:00',
      'items_snapshot': [
        {'name': 'Pho bo', 'quantity': '2', 'unit_price': '50000'},
        {'name': 'Tra da', 'quantity': 1, 'unit_price': 5000},
      ],
    });

    expect(batch.batchNo, 2);
    expect(batch.items, hasLength(2));
    expect(batch.items.first.name, 'Pho bo');
    expect(batch.items.first.quantity, 2);
    expect(batch.items.first.lineTotal, 100000);
    expect(batch.items.last.lineTotal, 5000);
  });

  test('QR order ledger tolerates an empty item snapshot', () {
    final batch = QrOrderLedgerBatch.fromJson({
      'batch_no': 1,
      'created_at': '2026-08-08T10:30:00Z',
      'items_snapshot': null,
    });

    expect(batch.items, isEmpty);
  });
}
