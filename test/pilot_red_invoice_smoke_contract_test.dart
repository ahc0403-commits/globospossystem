import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('pilot red invoice smoke runner samples card and e-pay safely', () {
    final script = readRepoFile('scripts/pilot_red_invoice_smoke.js');

    expect(script, contains("method: 'in.(CREDITCARD,OTHER)'"));
    expect(script, contains("is_revenue: 'eq.true'"));
    expect(script, contains("rpc('request_red_invoice'"));
    expect(script, contains('Math.ceil(eligiblePayments.length * rate)'));
    expect(script, contains('targetCount - alreadyRequested.length'));
    expect(script, contains("mode: execute ? 'execute' : 'dry-run'"));
    expect(script, contains("PILOT_RED_INVOICE_RATE || '0.10'"));
    expect(script, contains('PILOT_RED_INVOICE_STORE_ID'));
    expect(script, contains(".vercel', '.env.production.local'"));
    expect(script, contains('loadStoreEinvoiceConfig'));
    expect(script, contains('is_placeholder_tax_entity'));
    expect(script, contains('active_einvoice_shop_count'));
    expect(script, contains('skipped_without_einvoice_job'));
    expect(script, contains('payments_with_einvoice_job'));
    expect(script, isNot(contains(".from('einvoice_jobs').update")));
    expect(script, isNot(contains('UPDATE einvoice_jobs')));
    expect(script, isNot(contains('redinvoice_requested = TRUE')));
  });
}
