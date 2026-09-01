import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_copy.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_staff_service.dart';

void main() {
  const migrationPath =
      'supabase/migrations/20260901120000_direct_delivery_driver_receipt.sql';
  const runtimeContractPath =
      'supabase/tests/direct_delivery_driver_receipt_contract_test.sql';

  test('driver receipt migration is additive and preserves existing cores', () {
    final migration = File(migrationPath).readAsStringSync();

    expect(migration, contains('-- production-gate: self-verifying'));
    expect(migration, contains("'delivery_driver_receipt'"));
    expect(
      migration,
      contains(
        'CREATE OR REPLACE FUNCTION public.enqueue_direct_delivery_driver_receipt',
      ),
    );
    expect(
      migration,
      contains(
        'CREATE OR REPLACE FUNCTION public.direct_order_driver_receipt_status',
      ),
    );
    expect(migration, contains("destination.purpose = 'receipt'"));
    expect(
      migration,
      contains("'formatted_address', v_address.formatted_address"),
    );
    expect(migration, contains("'detail_address', v_address.detail_address"));
    expect(
      migration,
      contains("'delivery_fee_total', v_financial.delivery_fee_total"),
    );
    expect(migration, contains("'final_total', v_financial.final_total"));
    expect(migration, contains("'customer_due', 0"));
    expect(migration, contains('pg_advisory_xact_lock'));
    expect(migration, contains("job.batch_no = 1"));
    expect(migration, contains("job.status = 'done'"));
    expect(migration, contains("- 'formatted_address'"));
    expect(migration, contains("- 'customer_phone'"));
    expect(
      migration,
      contains('guard_direct_delivery_driver_receipt_job_trigger'),
    );
    expect(
      migration,
      contains('DIRECT_ORDER_DRIVER_RECEIPT_USE_DEDICATED_REPRINT'),
    );
    expect(migration, isNot(contains('actual_grab_fee')));
    expect(migration, isNot(contains('fee_variance')));
    expect(
      migration,
      isNot(contains('CREATE OR REPLACE FUNCTION public.process_payment')),
    );
    expect(
      migration,
      isNot(
        contains('CREATE OR REPLACE FUNCTION public.enqueue_receipt_print_job'),
      ),
    );
    expect(
      migration,
      isNot(
        contains(
          'CREATE OR REPLACE FUNCTION public.direct_order_approve_payment',
        ),
      ),
    );
  });

  test(
    'runtime SQL contract covers amount, PII, idempotency and isolation',
    () {
      final sql = File(runtimeContractPath).readAsStringSync();
      final fixture = File(
        'supabase/tests/fixtures/direct_delivery_test_fixture.sql',
      ).readAsStringSync();

      expect(sql, contains(r'\ir fixtures/direct_delivery_test_fixture.sql'));
      expect(fixture, contains("current_database() !~ '^codex_direct_'"));
      expect(sql, contains('first driver receipt contains exact address'));
      expect(sql, contains('completed driver receipt redacts PII'));
      expect(sql, contains('generic reprint cannot bypass'));
      expect(
        sql,
        contains('explicit reprint rebuilds current source snapshot'),
      );
      expect(sql, contains('kitchen role cannot inspect'));
      expect(sql, contains('driver printing remains isolated'));
      expect(sql, contains('ROLLBACK;'));
    },
  );

  test(
    'driver receipt status payload is parsed without leaking job payload',
    () {
      final status = DirectOrderDriverReceiptStatus.fromJson({
        'exists': true,
        'status': 'done',
        'batch_no': '2',
        'last_error_code': null,
        'can_reprint': true,
      });

      expect(status.exists, isTrue);
      expect(status.status, 'done');
      expect(status.batchNo, 2);
      expect(status.canReprint, isTrue);
    },
  );

  test('cashier copy covers driver receipt states in every locale', () {
    for (final locale in ['ko', 'vi', 'en']) {
      final copy = DirectOrderCopy(locale);
      expect(copy.driverReceipt, isNotEmpty);
      expect(copy.printDriverReceipt, isNotEmpty);
      expect(copy.reprintDriverReceipt, isNotEmpty);
      expect(copy.retryDriverReceipt, isNotEmpty);
      expect(
        copy.driverReceiptStatus('failed', errorCode: 'NO_DESTINATION'),
        isNotEmpty,
      );
      expect(copy.driverReceiptStatus('done', batchNo: 1), isNotEmpty);
    }
  });

  test('cashier and print agent use only the new isolated route', () {
    final cashier = File(
      'lib/features/direct_order/direct_order_cashier_screen.dart',
    ).readAsStringSync();
    final staff = File(
      'lib/features/direct_order/direct_order_staff_service.dart',
    ).readAsStringSync();
    final frozenAgent = File(
      'lib/core/hardware/print_job_agent_service.dart',
    ).readAsStringSync();
    final builder = File(
      'lib/core/hardware/receipt_builder.dart',
    ).readAsStringSync();

    expect(cashier, contains("'direct_order_driver_receipt_print'"));
    expect(cashier, contains("'direct_order_driver_receipt_reprint'"));
    expect(cashier, contains('_loadDriverReceiptStatus'));
    expect(staff, contains("'enqueue_direct_delivery_driver_receipt'"));
    expect(staff, contains("'direct_order_driver_receipt_status'"));
    expect(frozenAgent, isNot(contains('_buildDeliveryDriverReceipt')));
    expect(builder, contains("ticket.ticket == 'delivery_driver_receipt'"));
    expect(builder, contains('buildDeliveryDriverReceipt('));
  });
}
