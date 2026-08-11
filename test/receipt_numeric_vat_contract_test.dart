import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('receipt queue supplies the numeric order VAT to the printer', () {
    final migration = File(
      'supabase/migrations/20260811150000_numeric_vat_on_receipts.sql',
    ).readAsStringSync();
    final receiptBuilder = File(
      'lib/core/hardware/receipt_builder.dart',
    ).readAsStringSync();
    final printAgent = File(
      'lib/core/hardware/print_job_agent_service.dart',
    ).readAsStringSync();

    expect(migration, contains('SUM(oi.vat_amount)'));
    expect(migration, contains("'vat_amount', v_vat_amount"));
    expect(receiptBuilder, contains("payload['vat_amount']"));
    expect(receiptBuilder, contains("'VAT (da gom)', vatAmount"));
    expect(printAgent, contains('vatAmount: receipt.vatAmount'));
    expect(receiptBuilder, isNot(contains("text: '***'")));
  });
}
