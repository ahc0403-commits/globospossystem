import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

const _migrationPath =
    'supabase/migrations/20260821130000_direct_delivery_ordering.sql';

const _frozenFiles = <String, String>{
  'lib/features/qr_order/qr_order_screen.dart':
      '3be65edc63f943e3fddd1f4e4b25fca8b842d430e5fc803d54c76c9d75e7f49b',
  'lib/features/cashier/cashier_screen.dart':
      '60f007189e40d111d1e302d7719a9156b0cb9aaee8b12f3879b95f17ce5bee3e',
  'lib/features/kitchen/kitchen_provider.dart':
      '9fc393e5b61e1c370cbf17af31bb3becf6eae1cf87b3f8073164aa00ef345ec5',
  'lib/features/kitchen/kitchen_screen.dart':
      'e3cdc57c2a55ab67d948f7445fe18cac7305957153ef63ffff38b139bc5b5fa6',
  'lib/core/services/payment_service.dart':
      'ceb62497c8f43ed6cd0cd100ad3ac1c2f7ae5a9131184a4a48a7b002236ee28e',
  'lib/core/payments/payment_total_calculator.dart':
      '52cc2f364ce9f199e8727abf1eec5b43a4f0e2ba1c6821fd712df8122d69f0b8',
  'lib/features/report/report_provider.dart':
      '080ef129b8cf9d3b245c9218548ee67ad212e08adb0b0ea6f3a38d8182dbe5c1',
  'lib/core/hardware/print_job_agent_service.dart':
      '5c976d66666e47e3a9a2de7cf7cda39a6c6827792015cb414b118925409b03db',
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
