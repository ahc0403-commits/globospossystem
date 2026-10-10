import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

const _migrationPath =
    'supabase/migrations/20260821130000_direct_delivery_ordering.sql';

// Daily reset changes are covered by QR midnight and cashier clear/review
// widget tests, plus the isolated SQL behavior and concurrency suites.
const _frozenFiles = <String, String>{
  'lib/features/qr_order/qr_order_screen.dart':
      'fe1d5b4eca7bff30215b34919e59d46c7d65d0d3e2712c033e9a2a5d7bcd4228',
  // 2026-09-17: bank selection opens an amount-bearing QR before payment.
  // Single/combined QR and no-payment-on-close have operational coverage.
  // Cashier menu cancellation replaces the unserved-only action.
  // Timed KDS and cashier cancel/undo tests cover the requested workflow.
  // menu_language_switch_test + routed/overlay operational suites cover behavior.
  // Non-revenue checkout now reconfirms totals after concurrent additions.
  // Scheduled delivery closure disables reopen; cashier_overlay_operational_test
  // covers the CLOSED hours label while preserving existing checkout behavior.
  'lib/features/cashier/cashier_screen.dart':
      'bc2c4ef5f9ae85a1357ad8dd8b9b173ba1dfb1c332573677af9651ee7b32b7a0',
  // Bounded history and event-scoped reads are exercised with the real SDK
  // in kitchen_query_bounds_test and operational_refresh_realtime_test.
  // Forward cursor ordering also covers capped pages and missing changed IDs.
  // 2026-10-08: eager-load and retain item notes; menu-request behavior is
  // covered by direct_order_support_test and operational kitchen suites.
  'lib/features/kitchen/kitchen_provider.dart':
      'a78480eec8f93ba946dbef688ad5745930c5b469b7941d3a49b5a88a0e436cc8',
  'lib/features/kitchen/kitchen_screen.dart':
      '6239c0e8ca1dc2b55a83da7906fc2b4e0c9e5134f135bdf9e506b54be8787c4c',
  // Receipt detail eagerly includes menu requests in the existing query.
  // Payment detail contracts cover the read; the atomic payment SQL is frozen.
  'lib/core/services/payment_service.dart':
      '85442e4b0dd62d2fd540971b5b8d843c3590209299e6b4845bbfabc66032f34a',
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
  'lib/core/hardware/print_job_agent_service.dart':
      '287464ae95bdee00f2d4e12e651f6fd644bc7bf3deae0b0f20f481b27b89698a',
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
