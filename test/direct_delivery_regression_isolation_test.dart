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
      'd59581b768a7ff2fa65328be3cdc781ae0e5cef8653dbd8f3ad89f0c0d233fc9',
  // Bounded history and event-scoped reads are exercised with the real SDK
  // in kitchen_query_bounds_test and operational_refresh_realtime_test.
  // Forward cursor ordering also covers capped pages and missing changed IDs.
  'lib/features/kitchen/kitchen_provider.dart':
      'd49f47b8ffc105efff63f86698274b9aea28b5a195b8b79ce85237fd50cd921c',
  'lib/features/kitchen/kitchen_screen.dart':
      '6a485a44bde9887568dd3eaf22b0d0bbc0a0c72966920ff938f469a78a33d2ee',
  'lib/core/services/payment_service.dart':
      '8dedccd5c59bfb01b7b3fe4089fedca2450d2f2b031f801a24cd3b4ccba20402',
  // Sugar VAT and mixed combo amounts are covered by beverage_sugar_vat_test.
  'lib/core/payments/payment_total_calculator.dart':
      'ee04b6d78af1b0dfed8cd7669e2e3e513d9140ca5ed4e6a3f089c946186efb9b',
  // Phase 4D moves the reconciled sales report to a server aggregate.
  // Real SQL/API and Excel coverage lives in financial_inputs_postgrest_test.dart.
  'lib/features/report/report_provider.dart':
      'dd2d2e3ac50b1961c5fe3d99e17de6f585e84bf48aab137d79bef6f28f9a757a',
  // Direct fulfillment metadata passes through the existing payment renderer.
  // wifi_printer_service_test verifies printed pickup and both Grab payment modes.
  'lib/core/hardware/print_job_agent_service.dart':
      'bc78d9e92d1ed3716c0362e409a53baa7892e85c0bda445659476801fe7d4fca',
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
      r"RAISE EXCEPTION\s+'((?:DIRECT_ORDER|DIRECT_DELIVERY)_[A-Z0-9_]+)",
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
