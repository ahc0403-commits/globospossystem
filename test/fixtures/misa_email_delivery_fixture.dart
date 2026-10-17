import 'sales_invoice_fixture.dart';

/// Synthetic receipts only; no customer contact data.
List<Map<String, dynamic>>
misaEmailDeliveryFixtureJobs() => approvedSalesFixtureJobs([
  for (var i = 0; i < 4; i++)
    {
      'receipt_id': 'email-fixture-$i',
      'receipt_number': 'EMAIL-${i + 1}',
      'source_system': 'restaurant_pos',
      'tax_entity_id': 'fixture-entity',
      'created_at': '2026-10-17T0${i + 1}:00:00Z',
      if (i == 0) 'source_hash': 'preserved-source-hash',
      'snapshot_version': 2,
      'payment_method_snapshot': [
        'CASH',
        'BANKTRANSFER',
        'CASH/ATM',
        'EPAY',
      ][i],
      'payment_methods': [
        ['CASH'],
        ['BANKTRANSFER'],
        ['CASH', 'ATM'],
        ['EPAY'],
      ][i],
      'buyer_snapshot': {
        'unit_name': 'Synthetic buyer ${i + 1}',
        'email': [
          ' ; ; ',
          ' Solo@example.com ; SOLO@EXAMPLE.COM; ',
          ' Primary@example.com ; second@example.com;PRIMARY@EXAMPLE.COM;; ',
          'first@example.com; second@example.com;third@example.com',
        ][i],
      },
      'line_items_snapshot': [
        for (var j = 0; j < [2, 1, 3, 2][i]; j++)
          {
            'order_item_id': 'email-item-$i-$j',
            'invoice_name_vi': 'Synthetic item $i-$j',
            'misa_unit_name': 'Phần',
            'quantity': j + 1,
            'total_amount_ex_tax': 100000 * (j + 1),
            'vat_rate': j == 1 ? 10 : 8,
            'vat_amount': 1000 * (j + 1) * (j == 1 ? 10 : 8),
          },
      ],
    },
]);
