import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  const migrationPath =
      'supabase/migrations/20260706014000_print_routing_v1_m1.sql';
  const sqlContractPath = 'supabase/tests/print_routing_contract_test.sql';
  const receiptBuilderPath = 'lib/core/hardware/receipt_builder.dart';
  const agentServicePath = 'lib/core/hardware/print_job_agent_service.dart';
  const c2MigrationPath =
      'supabase/migrations/20260706015000_print_routing_v1_c2_admin.sql';
  const contractFixMigrationPath =
      'supabase/migrations/20260706016000_print_routing_v1_contract_fix.sql';
  const payloadFixMigrationPath =
      'supabase/migrations/20260706017000_print_routing_v1_payload_item_id_fix.sql';
  const testJobsMigrationPath =
      'supabase/migrations/20260706018000_print_routing_v1_test_jobs.sql';
  const receiptQueueMigrationPath =
      'supabase/migrations/20260710002000_receipt_print_queue.sql';
  const discountMigrationPath =
      'supabase/migrations/20260706010000_discount_staff_meal_v1_schema.sql';
  const destinationServicePath =
      'lib/core/services/printer_destination_service.dart';
  const destinationProviderPath =
      'lib/features/admin/providers/printer_destinations_provider.dart';
  const appRouterPath = 'lib/core/router/app_router.dart';
  const roleRoutesPath = 'lib/core/utils/role_routes.dart';
  const printStationScreenPath =
      'lib/features/print_station/print_station_screen.dart';
  const appEnPath = 'lib/l10n/app_en.arb';
  const appKoPath = 'lib/l10n/app_ko.arb';
  const appViPath = 'lib/l10n/app_vi.arb';

  test('print routing M1 migration is sequenced after discount M1-M3', () {
    final migration = File(migrationPath);

    expect(migration.existsSync(), isTrue);
    expect(
      migrationPath.compareTo(
            'supabase/migrations/20260706013000_discount_staff_meal_v1_meinvoice_guard.sql',
          ) >
          0,
      isTrue,
    );
  });

  test('print routing M1 adds additive floor and queue schema', () {
    final sql = readRepoFile(migrationPath);

    expect(sql, contains('ADD COLUMN IF NOT EXISTS floor_label text'));
    expect(
      sql,
      contains('CREATE TABLE IF NOT EXISTS public.printer_destinations'),
    );
    expect(
      sql,
      contains(
        "purpose text NOT NULL CHECK (purpose IN ('kitchen', 'floor', 'tray'))",
      ),
    );
    expect(sql, contains('CONSTRAINT floor_purpose_needs_label'));
    expect(sql, contains('CREATE TABLE IF NOT EXISTS public.print_jobs'));
    expect(
      sql,
      contains(
        "copy_type text NOT NULL CHECK (copy_type IN ('kitchen', 'floor', 'tray'))",
      ),
    );
    expect(sql, contains('CONSTRAINT print_jobs_idempotent'));
    expect(sql, contains('print_jobs_idempotent_missing_destination'));
    expect(sql, contains('CREATE INDEX IF NOT EXISTS print_jobs_pending'));
    expect(
      sql,
      contains(
        'ALTER PUBLICATION supabase_realtime ADD TABLE public.print_jobs',
      ),
    );
  });

  test('print routing M1 keeps direct writes RPC-only and store-scoped', () {
    final sql = readRepoFile(migrationPath);

    expect(
      sql,
      contains(
        'ALTER TABLE public.printer_destinations ENABLE ROW LEVEL SECURITY',
      ),
    );
    expect(
      sql,
      contains('ALTER TABLE public.print_jobs ENABLE ROW LEVEL SECURITY'),
    );
    expect(sql, contains('printer_destinations_store_read'));
    expect(sql, contains('print_jobs_store_read'));
    expect(
      sql,
      contains(
        'REVOKE ALL ON public.printer_destinations FROM PUBLIC, anon, authenticated',
      ),
    );
    expect(
      sql,
      contains(
        'REVOKE ALL ON public.print_jobs FROM PUBLIC, anon, authenticated',
      ),
    );
    expect(sql, contains('public.user_accessible_stores(auth.uid())'));
    expect(
      sql,
      contains("u.role IN ('kitchen', 'admin', 'store_admin', 'super_admin')"),
    );
  });

  test('enqueue hooks cover initial, delta, serving edge, and cancel', () {
    final sql = readRepoFile(migrationPath);

    expect(
      sql,
      contains('CREATE OR REPLACE FUNCTION public.enqueue_print_jobs'),
    );
    expect(sql, contains('EXCEPTION WHEN OTHERS THEN'));
    expect(sql, contains("'print_enqueue_failed'"));
    expect(sql, contains("'NO_DESTINATION'"));
    expect(sql, contains("ARRAY['kitchen', 'floor']"));
    expect(sql, contains("'initial'"));
    expect(sql, contains("'added_items'"));
    expect(
      sql.indexOf('One operational event must produce one batch number'),
      lessThan(sql.indexOf('FOREACH v_copy_type IN ARRAY p_copy_types LOOP')),
    );
    expect(
      sql,
      contains("IF v_next = 'serving' AND v_order.status <> 'serving' THEN"),
    );
    expect(sql, contains('v_tray_batch_no int'));
    expect(sql, contains("'item_id', oi.id::text"));
    expect(sql, contains("prior.copy_type = 'tray'"));
    expect(
      sql,
      contains("NULLIF(prior_item.raw->>'item_id', '') = oi.id::text"),
    );
    expect(sql, contains('IF jsonb_array_length(v_tray_items) > 0 THEN'));
    expect(sql, contains("ARRAY['tray']"));
    expect(sql, contains("'serving'"));
    expect(
      sql,
      contains(
        "WHERE order_id = p_order_id\n    AND status IN ('pending', 'failed')",
      ),
    );
    expect(
      sql,
      contains(
        'CREATE OR REPLACE FUNCTION public.cancel_order(\n  p_order_id uuid,\n  p_store_id uuid,\n  p_allow_served boolean DEFAULT false',
      ),
    );
    expect(sql, contains("v_order.status IN ('completed', 'cancelled')"));
    expect(sql, contains("v_order.status = 'serving'"));
    expect(sql, contains('ORDER_SERVING_CANCEL_ADMIN_REQUIRED'));
    expect(sql, contains('p_allow_served'));
    expect(
      sql,
      contains(
        "WHERE order_id = p_order_id\n    AND status IN ('pending', 'failed')",
      ),
    );
  });

  test(
    'print routing hooks staff meal initial tickets when print helper exists',
    () {
      final sql = readRepoFile(discountMigrationPath);

      expect(
        sql,
        contains('CREATE OR REPLACE FUNCTION public.create_staff_meal_order'),
      );
      expect(
        sql,
        contains(
          "to_regprocedure('public.enqueue_print_jobs(uuid,text[],jsonb,text)')",
        ),
      );
      expect(sql, contains("ARRAY['kitchen', 'floor']"));
      expect(sql, contains("'initial'"));
    },
  );

  test('print routing follow-up migrations preserve final deployed contracts', () {
    final contractFix = readRepoFile(contractFixMigrationPath);
    final payloadFix = readRepoFile(payloadFixMigrationPath);
    final testJobs = readRepoFile(testJobsMigrationPath);

    expect(
      contractFix,
      contains('CREATE OR REPLACE FUNCTION public.recalc_order_status'),
    );
    expect(contractFix, contains("v_next = 'serving'"));
    expect(contractFix, contains("'item_id', oi.id::text"));
    expect(contractFix, contains("prior.copy_type = 'tray'"));
    expect(
      contractFix,
      contains(
        'CREATE OR REPLACE FUNCTION public.cancel_order(\n  p_order_id uuid,\n  p_store_id uuid,\n  p_allow_served boolean DEFAULT false',
      ),
    );
    expect(contractFix, contains('ORDER_SERVING_CANCEL_ADMIN_REQUIRED'));

    expect(
      payloadFix,
      contains('CREATE OR REPLACE FUNCTION public.enqueue_print_jobs'),
    );
    expect(payloadFix, contains("'item_id', NULLIF(item.raw->>'item_id', '')"));
    expect(payloadFix, contains("'print_enqueue_failed'"));

    expect(
      testJobs,
      contains(
        'ALTER TABLE public.print_jobs\n  ALTER COLUMN order_id DROP NOT NULL',
      ),
    );
    expect(
      testJobs,
      contains(
        'CREATE OR REPLACE FUNCTION public.admin_enqueue_printer_test_job',
      ),
    );
    expect(testJobs, contains("'printed_reason', 'test_print'"));
    expect(
      testJobs,
      contains(
        'GRANT EXECUTE ON FUNCTION public.admin_enqueue_printer_test_job(uuid, uuid)',
      ),
    );
  });

  test('agent RPCs implement claim, bounded retry, and reprint contract', () {
    final sql = readRepoFile(migrationPath);

    expect(sql, contains('CREATE OR REPLACE FUNCTION public.claim_print_jobs'));
    expect(sql, contains('FOR UPDATE SKIP LOCKED'));
    expect(sql, contains('attempts < 10'));
    expect(sql, contains("destination_id IS NOT NULL"));
    expect(
      sql,
      contains('CREATE OR REPLACE FUNCTION public.complete_print_job'),
    );
    expect(
      sql,
      contains("make_interval(secs => LEAST(GREATEST(attempts, 1), 5) * 20)"),
    );
    expect(
      sql,
      contains('CREATE OR REPLACE FUNCTION public.reprint_print_job'),
    );
    expect(
      sql,
      contains(
        "jsonb_set(v_source.payload, '{printed_reason}', to_jsonb('reprint'::text), true)",
      ),
    );
    expect(sql, contains('REVOKE ALL ON FUNCTION public.claim_print_jobs'));
    expect(sql, contains('GRANT EXECUTE ON FUNCTION public.reprint_print_job'));
  });

  test('print routing Gate-2 contract exercises callable RPC paths', () {
    final sql = readRepoFile(sqlContractPath);

    for (var i = 0; i <= 10; i++) {
      expect(sql, contains('TP$i'));
    }
    expect(sql, contains('lives_ok'));
    expect(sql, contains('public.enqueue_print_jobs'));
    expect(sql, contains('public.recalc_order_status'));
    expect(sql, contains('public.cancel_order'));
    expect(sql, contains('public.claim_print_jobs'));
    expect(sql, contains('public.complete_print_job'));
    expect(sql, contains('public.reprint_print_job'));
    expect(sql, contains('public.admin_enqueue_printer_test_job'));
    expect(sql, contains('jsonb_array_length'));
    expect(sql, contains("payload->'items'"));
    expect(sql, contains('NO_DESTINATION'));
    expect(sql, contains('PRINT_CLAIM_FORBIDDEN'));
    expect(sql, contains('attempts = 10'));
    expect(sql, contains('print_enqueue_failed'));
    expect(sql, contains('throws_ok'));
    expect(sql, isNot(contains('pg_get_functiondef')));
  });

  test('receipt printing extends the queue without coupling payment', () {
    final migration = readRepoFile(receiptQueueMigrationPath);
    final agent = readRepoFile(agentServicePath);
    final service = readRepoFile('lib/core/services/payment_service.dart');

    expect(
      migration,
      contains("purpose IN ('kitchen', 'floor', 'tray', 'receipt')"),
    );
    expect(
      migration,
      contains(
        "copy_type IN ('kitchen', 'floor', 'tray', 'confirmation', 'receipt')",
      ),
    );
    expect(
      migration,
      contains('CREATE OR REPLACE FUNCTION public.enqueue_receipt_print_job'),
    );
    expect(migration, contains("purpose = 'receipt'"));
    expect(migration, contains("'printed_reason', CASE"));
    expect(migration, contains("'NO_DESTINATION'"));
    expect(agent, contains("'receipt' => _buildPaymentReceipt(job.payload)"));
    expect(service, contains("'enqueue_receipt_print_job'"));
  });

  test('print routing C1 Flutter layer keeps printing native-agent based', () {
    final receiptBuilder = readRepoFile(receiptBuilderPath);
    final agentService = readRepoFile(agentServicePath);

    expect(receiptBuilder, contains('buildKitchenTicket'));
    expect(receiptBuilder, contains('buildFloorTicket'));
    expect(receiptBuilder, contains('buildTrayLabel'));
    expect(receiptBuilder, contains('PrintTicket.fromPayload'));
    expect(agentService, contains('bool get isSupported => !kIsWeb'));
    expect(agentService, contains("rpc(\n      'claim_print_jobs'"));
    expect(agentService, contains("rpc(\n      'complete_print_job'"));
    expect(agentService, contains('_printerService.printReceipt'));
    expect(agentService, contains('startPolling'));
    expect(agentService, contains('subscribeToJobs'));
    expect(agentService, contains("LiveSyncScope.storeChannel('print_jobs'"));
    expect(agentService, contains('onPostgresChanges'));
    expect(agentService, contains('testPrintDestination'));
  });

  test('print routing C2 adds admin RPCs without direct destination writes', () {
    final sql = readRepoFile(c2MigrationPath);

    expect(
      sql,
      contains('CREATE OR REPLACE FUNCTION public.admin_create_table'),
    );
    expect(sql, contains('p_floor_label text DEFAULT'));
    expect(sql, contains('TABLE_FLOOR_LABEL_REQUIRED'));
    expect(
      sql,
      contains('CREATE OR REPLACE FUNCTION public.admin_update_table'),
    );
    expect(sql, contains('floor_label = v_floor_label'));
    expect(
      sql,
      contains(
        'CREATE OR REPLACE FUNCTION public.admin_upsert_printer_destination',
      ),
    );
    expect(sql, contains('PRINTER_FLOOR_LABEL_REQUIRED'));
    expect(
      sql,
      contains(
        'CREATE OR REPLACE FUNCTION public.admin_delete_printer_destination',
      ),
    );
    expect(sql, contains('SET is_active = false'));
    expect(
      sql,
      contains(
        'GRANT EXECUTE ON FUNCTION public.admin_upsert_printer_destination',
      ),
    );
    expect(
      sql,
      contains(
        'GRANT EXECUTE ON FUNCTION public.admin_upsert_printer_destination(uuid, uuid, text, text, int, text, text, boolean) TO service_role',
      ),
    );
    expect(
      sql,
      contains(
        'GRANT EXECUTE ON FUNCTION public.admin_delete_printer_destination(uuid, uuid) TO service_role',
      ),
    );
    expect(sql, contains('public.require_admin_actor_for_restaurant'));
  });

  test('print routing C2 Flutter config stays RPC backed', () {
    final service = readRepoFile(destinationServicePath);
    final provider = readRepoFile(destinationProviderPath);
    final settingsScreen = readRepoFile(
      'lib/features/admin/tabs/settings_tab.dart',
    );

    expect(service, contains('class PrinterDestinationConfig'));
    expect(service, contains('class PrinterDestinationDraft'));
    expect(service, contains(".from('printer_destinations')"));
    expect(service, contains("'admin_upsert_printer_destination'"));
    expect(service, contains("'admin_delete_printer_destination'"));
    expect(service, contains("'admin_enqueue_printer_test_job'"));
    expect(provider, contains('printerDestinationsProvider'));
    expect(provider, contains('upsertDestination'));
    expect(provider, contains('deleteDestination'));
    expect(provider, contains('enqueueTestPrintJob'));
    expect(provider, contains('PRINTER_FLOOR_LABEL_REQUIRED'));
    expect(settingsScreen, contains('enqueueTestPrintJob(destination.id)'));
    expect(
      settingsScreen,
      isNot(contains('testPrintDestination(destination.id)')),
    );
  });

  test('print routing C2 exposes a native print station route', () {
    final router = readRepoFile(appRouterPath);
    final roleRoutes = readRepoFile(roleRoutesPath);
    final printStation = readRepoFile(printStationScreenPath);
    final kitchenScreen = readRepoFile(
      'lib/features/kitchen/kitchen_screen.dart',
    );
    final settingsScreen = readRepoFile(
      'lib/features/admin/tabs/settings_tab.dart',
    );

    expect(router, contains("path: '/print-station'"));
    expect(router, contains('PrintStationScreen'));
    expect(router, contains('PlatformInfo.isPrinterSupported'));
    expect(roleRoutes, contains("path == '/print-station'"));
    expect(roleRoutes, contains("'kitchen' => true"));
    expect(
      roleRoutes,
      contains(
        "'super_admin' || 'store_admin' || 'admin' || 'kitchen' => true",
      ),
    );
    expect(printStation, contains('class PrintStationScreen'));
    expect(printStation, contains('PrintJobAgentService'));
    expect(printStation, contains('startPolling(storeId)'));
    expect(printStation, contains('processOnce(storeId)'));
    expect(printStation, contains('printStationJobsProvider(storeId)'));
    expect(printStation, contains('testPrintDestination(destination.id)'));
    expect(printStation, contains('reprintPrintJob(job.id)'));
    expect(printStation, contains("Key('print_station_root')"));
    expect(printStation, contains("Key('print_station_job_feed')"));
    expect(printStation, contains("Key('print_station_destination_test')"));
    expect(printStation, contains("Key('print_station_reprint_job_button')"));
    expect(kitchenScreen, contains("Key('kitchen_print_station_entry')"));
    expect(settingsScreen, contains("Key('settings_print_station_open')"));
  });

  test(
    'print routing C2 localization covers admin, kitchen, and station copy',
    () {
      for (final path in [appEnPath, appKoPath, appViPath]) {
        final arb = readRepoFile(path);

        expect(arb, contains('settingsPrintRoutingDestinationsTitle'));
        expect(arb, contains('settingsPrintDestinationTestComplete'));
        expect(arb, contains('printStationOpen'));
        expect(arb, contains('kitchenFailedPrintJobs'));
        expect(arb, contains('printStationTitle'));
        expect(arb, contains('printStationJobFeed'));
        expect(arb, contains('printStationReprint'));
        expect(arb, contains('printStationLastRunSummary'));
      }
    },
  );
}
