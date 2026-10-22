import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

const _migrationPath =
    'supabase/migrations/20260821130000_direct_delivery_ordering.sql';

// Daily reset changes are covered by QR midnight and cashier clear/review
// widget tests, plus the isolated SQL behavior and concurrency suites.
// 2026-10-19: terminal auth and printer mode copy have browser/native
// isolation, profile recovery and settings refresh behavior coverage.
// 2026-10-20: QR carries registered option keys; menu_portion_spice_test
// and SQL regression cover stale choice rejection and S/L separation.
// Owner-corrected size selection uses one catalog card and retains chosen price
// IDs. QR operational UI tests cover KO/VI/EN, 200% text, stale price reset,
// and retention of the registered photo and description.
// 2026-10-21: editable customer cart is covered by QR operational tests for
// both S/L insertion orders, meal choices, edits/removal and no premature submit.
// QR VAT copy excludes tax without asserting one rate for mixed-rate items;
// qr_order_operational_ui_test covers the notice and scaled viewport layout.
// Registered generic choices now share the same QR cart. The operational QR
// tests cover two selections of one menu, real sellable IDs, explicit submit,
// old S/L and noodles/rice, and stale selection handling.
// 2026-10-22: meal choices use an options label; size-only dishes retain
// the size label. qr_order_operational_ui_test covers the registered choices.
const _frozenFiles = <String, String>{
  'lib/features/qr_order/qr_order_screen.dart':
      '807c21e6948ef488ea648cb95e339b621bf1177c7fdc9bdd0f61b31dba83461b',
  // 2026-09-17: bank selection opens an amount-bearing QR before payment.
  // Single/combined QR and no-payment-on-close have operational coverage.
  // Cashier menu cancellation replaces the unserved-only action.
  // Timed KDS and cashier cancel/undo tests cover the requested workflow.
  // menu_language_switch_test + routed/overlay operational suites cover behavior.
  // 2026-10-11: corporate bank snapshots replace the personal beneficiary.
  // Cashier QR and customer display tests verify the bank and amount.
  // Non-revenue checkout now reconfirms totals after concurrent additions.
  // Scheduled delivery closure disables reopen; cashier_overlay_operational_test
  // covers the CLOSED hours label while preserving existing checkout behavior.
  // 2026-10-21: explicit staff/influencer selection retains the existing
  // atomic SERVICE payment and manager PIN; desktop/compact selection,
  // wet-tissue gating and offline behavior have operational widget coverage.
  'lib/features/cashier/cashier_screen.dart':
      '4b57518e1ed51024498f22513a2b6c915254a97c20eaa23da76719a723168c7c',
  // 2026-10-20: immutable portion/spice names are covered by menu_portion_spice_test.
  // Bounded history and event-scoped reads are exercised with the real SDK
  // in kitchen_query_bounds_test and operational_refresh_realtime_test.
  // Forward cursor ordering also covers capped pages and missing changed IDs.
  // 2026-10-08: eager-load and retain item notes; menu-request behavior is
  // covered by direct_order_support_test and operational kitchen suites.
  'lib/features/kitchen/kitchen_provider.dart':
      'fd35d653c09194249454d882aa5a5143df2827a68be7b2a441ea46b64c70cb25',
  'lib/features/kitchen/kitchen_screen.dart':
      '6239c0e8ca1dc2b55a83da7906fc2b4e0c9e5134f135bdf9e506b54be8787c4c',
  // Receipt detail eagerly includes menu requests in the existing query.
  // Payment detail contracts cover the read; the atomic payment SQL is frozen.
  'lib/core/services/payment_service.dart':
      '51f9d181fce06b2efb94ac073da3393e6e98a07ee418df252c812921fb9c0beb',
  // Sugar VAT and mixed combo amounts are covered by beverage_sugar_vat_test.
  'lib/core/payments/payment_total_calculator.dart':
      'ee04b6d78af1b0dfed8cd7669e2e3e513d9140ca5ed4e6a3f089c946186efb9b',
  // Phase 4D moves the reconciled sales report to a server aggregate.
  // Real SQL/API and Excel coverage lives in financial_inputs_postgrest_test.dart.
  'lib/features/report/report_provider.dart':
      '8ba89ba7b6937baecb78dd5bde9b9751ed160634b7d2ba536909b9ab0cba0548',
  // 2026-10-06: forward the direct order reference for packing headers.
  // Runtime queue->agent bytes coverage verifies 3 sets; regular receipts
  // retain their existing financial behavior and have no utensil block.
  // 2026-10-08: forward customer requests to the same queued receipt builder.
  // 2026-10-10: forward the independent utensils flag; byte tests retain diners
  // and verify opt-out across all packing forms without changing money.
  // 2026-10-10: confirmed-request addenda render as memo slips; destinations
  // and physical endpoints are fetched in two batch reads for 1/10/50 printers.
  // direct_order_requirements_test + wifi_printer_service_test cover the path.
  // 2026-10-13: pass the server's immutable beneficiary to the receipt QR.
  // receipt_builder_contract_test retains pickup/delivery and validates QR bytes.
  // 2026-10-13: retain endpoint errors and stop uncertain-send retries.
  // print_station_connection_regression_test covers diagnostics and duplicates;
  // wifi_printer_service_test retains packing forms and batch destination reads.
  'lib/core/hardware/print_job_agent_service.dart':
      'c38f83cf1375883ae2cc4cf7fe8393a162f1b846717846a04db28f61d4d66adc',
  'supabase/migrations/20260707010000_service_item_exclusion_v1.sql':
      '812fdaa3f993520983fc87e4bdb2c1f28c7ccca23f0eb384d69fdf42f4101993',
  'supabase/migrations/20260722050000_kitchen_direct_completion.sql':
      '41a7dbc9ddb195db909d8578ce9286dc5de411e2ed67a1cfa657f1ea462b4e97',
  'supabase/migrations/20260817110000_menu_scoped_promotion_integrity.sql':
      '5b5b441698b0921d837966a1976465650409005a875f0214628939ebc3bcc2e4',
};

void main() {
  test('direct delivery migration is expand-only around legacy domains', () {
    final sql = File(_migrationPath).readAsStringSync().toLowerCase();

    const forbiddenFragments = <String>[
      'alter table public.orders',
      'alter table orders',
      'alter table public.order_items',
      'alter table order_items',
      'alter table public.payments',
      'alter table payments',
      'alter table public.print_jobs',
      'alter table print_jobs',
      'create or replace function public.process_payment',
      'create or replace function public.create_order',
      'create or replace function public.qr_get_menu',
      'create or replace function public.qr_submit_order',
      'drop table public.orders',
      'drop table public.order_items',
      'drop table public.payments',
    ];

    for (final fragment in forbiddenFragments) {
      expect(
        sql,
        isNot(contains(fragment)),
        reason: 'legacy object mutation is forbidden: $fragment',
      );
    }

    expect(sql, contains('public.direct_order_approve_payment('));
    expect(
      RegExp(
        r'v_payment\s*:=\s*public\.process_payment\(',
      ).allMatches(sql).length,
      1,
      reason: 'approval must use the unchanged atomic payment anchor once',
    );
    expect(sql, contains("'direct_order_financial_reconciliation_failed'"));
    expect(sql, contains("is_enabled boolean not null default false"));
  });

  test(
    'frozen QR, cashier, KDS, payment, report, and print files stay exact',
    () {
      for (final entry in _frozenFiles.entries) {
        final file = File(entry.key);
        expect(
          file.existsSync(),
          isTrue,
          reason: 'missing frozen file ${entry.key}',
        );
        final actual = sha256.convert(file.readAsBytesSync()).toString();
        expect(
          actual,
          entry.value,
          reason: 'frozen file changed: ${entry.key}',
        );
      }
    },
  );

  test('public contract uses Edge-only RPCs and private proof storage', () {
    final sql = File(_migrationPath).readAsStringSync().toLowerCase();

    expect(sql, contains("'direct-order-proofs'"));
    expect(sql, contains("'direct-order-proofs',\n  false"));
    expect(
      sql,
      contains(
        'revoke all on function '
        'public.direct_order_public_submit(uuid, text, uuid, jsonb)',
      ),
    );
    expect(
      sql,
      isNot(
        contains(
          'grant execute on function '
          'public.direct_order_public_submit(uuid, text, uuid, jsonb)\n'
          '  to anon',
        ),
      ),
    );
    expect(
      utf8.decode(File(_migrationPath).readAsBytesSync()),
      contains('No direct storage policy is created.'),
    );
  });

  test('every SQL domain exception has an explicit Edge registry entry', () {
    final migration = Directory('supabase/migrations')
        .listSync()
        .whereType<File>()
        .where((file) => file.path.endsWith('.sql'))
        .map((file) => file.readAsStringSync())
        .join('\n');
    final edge = File(
      'supabase/functions/direct-order-public/index.ts',
    ).readAsStringSync();
    final raisedCodes = RegExp(
      r"RAISE EXCEPTION\s+'{1,2}((?:DIRECT_ORDER|DIRECT_DELIVERY)_[A-Z0-9_]+)",
      caseSensitive: false,
    ).allMatches(migration).map((match) => match.group(1)!.toUpperCase()).toSet();
    final registeredCodes = RegExp(
      r'^\s{2}((?:DIRECT_ORDER|DIRECT_DELIVERY)_[A-Z0-9_]+):',
      multiLine: true,
    ).allMatches(edge).map((match) => match.group(1)!).toSet();

    expect(registeredCodes, raisedCodes);
    expect(
      edge,
      isNot(contains('message.includes("INVALID")')),
      reason: 'SQL errors must not be classified by fuzzy substrings',
    );
    expect(
      edge,
      isNot(contains('message.includes("NOT_FOUND")')),
      reason: 'new SQL errors must default to a sanitized 503',
    );
  });
}
