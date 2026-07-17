import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  group('pilot Gate 3 fixture and audit contracts', () {
    test(
      'fixture seed keeps secrets out of source and marks cleanup scope',
      () {
        final seed = readRepoFile('scripts/pilot_gate3_fixture_seed.sql');

        expect(seed, contains('__SMOKE_SHARED_PASSWORD__'));
        expect(seed, contains('pilot_gate3.smoke_password'));
        expect(seed, contains("'qa_run_id', v_qa_run_id"));
        expect(seed, contains("'cleanup_scope', 'dedicated_fixture_store'"));
        expect(seed, isNot(contains('SMOKE_SHARED_PASSWORD=')));
      },
    );

    test(
      'operational audit covers QR replay, print routing, store scope, refund, and close',
      () {
        final audit = readRepoFile('scripts/pilot_gate3_operational_audit.sql');

        expect(audit, contains('BEGIN;'));
        expect(audit, contains('ROLLBACK;'));
        expect(audit, contains('qr_place_order'));
        expect(
          audit,
          contains('QR replay keeps the same client order idempotent'),
        );
        expect(audit, contains("pj.copy_type = 'confirmation'"));
        expect(
          audit,
          contains("COALESCE(pj.last_error, '') <> 'NO_DESTINATION'"),
        );
        expect(audit, contains('search_active_order_for_cashier'));
        expect(audit, contains('STORE_ACCESS_DENIED'));
        expect(audit, contains('record_payment_adjustment'));
        expect(audit, contains('create_daily_closing'));
        expect(audit, contains('PILOT_GATE3_OPERATIONAL_AUDIT_READY'));
      },
    );

    test('web route smoke checks deployed QR-capable build markers', () {
      final smoke = readRepoFile('scripts/pilot_gate3_web_route_smoke.sh');

      expect(smoke, contains('https://globospossystem.vercel.app'));
      expect(smoke, contains(r'/#/qr/${QR_TOKEN}'));
      expect(smoke, contains('qr_order_screen'));
      expect(smoke, contains('admin_table_qr_dialog'));
      expect(smoke, contains('cashier_qr_order_badge'));
      expect(smoke, contains('print_station_root'));
      expect(smoke, contains('PILOT_GATE3_WEB_ROUTE_SMOKE_READY'));
    });

    test('multi-account smoke can run against dedicated fixture accounts', () {
      final smoke = readRepoFile(
        'integration_test/full_multi_account_smoke_test.dart',
      );

      expect(smoke, contains('SMOKE_WAITER_EMAIL'));
      expect(smoke, contains('SMOKE_KITCHEN_EMAIL'));
      expect(smoke, contains('SMOKE_CASHIER_EMAIL'));
      expect(smoke, contains('SMOKE_ADMIN_EMAIL'));
      expect(smoke, contains('SMOKE_SUPERADMIN_EMAIL'));
      expect(smoke, contains('SMOKE_VALIDATION_EMAIL'));
      expect(smoke, contains('SMOKE_SHARED_PASSWORD'));
      expect(smoke, contains('Required surface features missing'));
      expect(
        smoke,
        contains('waiter_order requires menu_first_item and cart_submit_order'),
      );
    });
  });
}
