import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  const migrationPath =
      'supabase/migrations/20260630002000_meinvoice_dispatcher_foundation.sql';
  const readinessPath =
      'supabase/migrations/20260630004000_meinvoice_readiness.sql';
  const configAdminPath =
      'supabase/migrations/20260630005000_meinvoice_config_admin.sql';
  const readyQueueAdminPath =
      'supabase/migrations/20260630006000_meinvoice_ready_queue_admin.sql';
  const sharedPath = 'supabase/functions/_shared/meinvoice.ts';
  const dispatcherPath = 'supabase/functions/meinvoice-dispatcher/index.ts';

  test(
    'dispatcher migration adds safe MISA runtime state without scheduling',
    () {
      final sql = readRepoFile(migrationPath);

      expect(sql, contains('meinvoice_token_cache'));
      expect(sql, contains('meinvoice_job_events'));
      expect(sql, contains("metadata jsonb NOT NULL DEFAULT '{}'::jsonb"));
      expect(sql, contains('ADD COLUMN IF NOT EXISTS metadata jsonb'));
      expect(
        sql,
        contains(
          'Store safe metadata summaries; do not persist raw invoice payloads or MISA responses.',
        ),
      );
      expect(sql, contains('meinvoice_dispatch_enabled'));
      expect(sql, contains('meinvoice_dispatch_batch_size'));
      expect(sql, contains('meinvoice_token_refresh_skew_minutes'));
      expect(sql, contains('dispatch_attempts'));
      expect(sql, contains('last_dispatch_at'));
      expect(sql, contains('sent_at'));
      expect(sql, contains('https://api.meinvoice.vn/api/integration'));
      expect(sql, contains('https://api.meinvoice.vn/api/integration/invoice'));
      expect(sql, contains('ENABLE ROW LEVEL SECURITY'));
      expect(sql, isNot(contains('cron.schedule')));
      expect(sql, isNot(contains('wetax-dispatcher')));
      expect(
        sql,
        isNot(
          contains(
            'invoice'
            'andpublish',
          ),
        ),
      );
    },
  );

  test(
    'shared adapter follows MISA cash-register token and publish contracts',
    () {
      final source = readRepoFile(sharedPath);

      expect(source, contains('/auth/token'));
      expect(source, contains('appid'));
      expect(source, contains('taxcode'));
      expect(source, contains('username'));
      expect(source, contains('password'));
      expect(source, contains('meinvoice_token_cache'));
      expect(source, contains('parseJwtExpiry'));
      expect(
        source,
        contains('https://api.meinvoice.vn/api/integration/invoice'),
      );
      expect(source, contains('SignType: 5'));
      expect(source, contains('InvoiceData: [compact({'));
      expect(source, isNot(contains('CompanyTaxCode'.toLowerCase())));
      expect(source, isNot(contains('/code/itg/invoice-calculating')));
      expect(
        source,
        isNot(
          contains(
            'invoice'
            'andpublish',
          ),
        ),
      );
      expect(source, contains('IsInvoiceCalculatingMachine'));
      expect(source, contains('TotalAmountInWords'));
      expect(source, contains('vietnameseVndWords'));
      expect(source, contains('OriginalInvoiceDetail'));
      expect(source, contains('TaxRateInfo'));
      expect(source, contains('OptionUserDefined'));
      expect(source, contains('ItemType: 1'));
      expect(source, contains('PaymentMethodName'));
      expect(source, contains('validateCashRegisterInvoicePayload'));
      expect(source, contains('MEINVOICE_PAYLOAD_INVALID'));
      expect(source, contains('assertPayloadReady'));
      final payloadBuilderStart = source.indexOf(
        'export function buildCashRegisterInvoicePayload',
      );
      final payloadBuilderEnd = source.indexOf(
        'function invalidPayload',
        payloadBuilderStart,
      );
      final tokenStart = source.indexOf(
        'export async function getMeInvoiceToken',
      );
      expect(payloadBuilderStart, greaterThan(-1));
      expect(payloadBuilderEnd, greaterThan(payloadBuilderStart));
      expect(tokenStart, greaterThan(-1));
      final payloadBuilder = source.substring(
        payloadBuilderStart,
        payloadBuilderEnd,
      );
      final tokenSection = source.substring(tokenStart);
      expect(payloadBuilder, contains('assertPayloadReady(seller);'));
      expect(payloadBuilder, isNot(contains('assertDispatchReady(seller);')));
      expect(tokenSection, contains('assertDispatchReady(seller);'));
      expect(source, contains('summarizePublishResponse'));
      expect(source, contains('metadata: options.metadata'));
      expect(source, contains('publishInvoiceResult'));
      expect(source, contains('getMeInvoiceTemplates'));
      expect(source, contains('getCashRegisterInvoiceStatus'));
      expect(source, contains('downloadCashRegisterInvoice'));
      expect(source, contains('/templates'));
      expect(source, contains('/status'));
      expect(source, contains('/Download'));
      expect(source, contains('invoiceCalcu'));
      expect(
        source,
        isNot(
          contains(
            'OrgInvoice'
            'Data',
          ),
        ),
      );
      expect(source, contains('OriginalInvoiceDetail.Quantity'));
      expect(source, contains('OriginalInvoiceDetail.ItemType'));
      expect(source, contains('TaxRateInfo.VATAmount'));
      expect(source, contains('BuyerTaxCode'));
      expect(source, contains('BuyerLegalName'));
      expect(source, contains('BuyerFullName'));
      expect(source, contains('ContactName'));
      expect(source, contains('MISA_MEINVOICE_USERNAME'));
      expect(source, contains('MISA_MEINVOICE_PASSWORD'));
      expect(source, isNot(contains('WETAX_BASE_URL')));
    },
  );

  test('dispatcher is guarded and only processes meInvoice pending jobs', () {
    final source = readRepoFile(dispatcherPath);
    final shared = readRepoFile(sharedPath);

    expect(source, contains('CRON_SECRET'));
    expect(source, contains('METHOD_NOT_ALLOWED'));
    expect(source, contains('dry_run'));
    expect(source, contains('meinvoice_dispatch_disabled'));
    expect(source, contains('.from("meinvoice_jobs")'));
    expect(source, contains('.eq("status", "pending")'));
    expect(source, contains('loadSellerConfig'));
    expect(source, contains('buildCashRegisterInvoicePayload'));
    expect(source, contains('validateCashRegisterInvoicePayload'));
    expect(source, contains('summarizePublishResponse'));
    expect(source, contains('metadata: publishMetadata'));
    expect(source, contains('getMeInvoiceToken'));
    expect(source, contains('publishCashRegisterInvoice'));
    expect(source, contains('status: "valid_invoice"'));
    expect(source, contains('status: "dispatch_paused"'));
    expect(source, contains('logMeInvoiceEvent'));
    expect(shared, contains('meinvoice_job_events'));
    final validationCall = source.indexOf(
      'const payload = validateCashRegisterInvoicePayload(',
    );
    expect(validationCall, greaterThan(-1));
    expect(validationCall, lessThan(source.indexOf('if (dryRun)')));
    expect(
      validationCall,
      lessThan(source.indexOf('const token = await getMeInvoiceToken')),
    );
    expect(source, isNot(contains('.from("einvoice_jobs")')));
    expect(source, isNot(contains('wetax')));
    expect(source, isNot(contains('rawRequest')));
    expect(source, isNot(contains('rawResponse')));
  });

  test('admin surface and payment status use meInvoice jobs', () {
    final admin = readRepoFile('lib/features/admin/tabs/einvoice_tab.dart');
    final paymentService = readRepoFile(
      'lib/core/services/payment_service.dart',
    );
    final statusProvider = readRepoFile(
      'lib/features/payment/einvoice_provider.dart',
    );
    final statusBadge = readRepoFile(
      'lib/features/payment/einvoice_status_badge.dart',
    );
    final paymentDetail = readRepoFile(
      'lib/features/payment/payment_detail_screen.dart',
    );
    final adminOps = readRepoFile(
      'supabase/migrations/20260630003000_meinvoice_admin_ops.sql',
    );

    expect(admin, contains(".from('meinvoice_jobs')"));
    expect(admin, contains('meinvoice_dispatch_enabled'));
    expect(admin, contains('_meinvoiceReadinessProvider'));
    expect(admin, contains('get_meinvoice_readiness'));
    expect(admin, contains('_buildReadinessAlerts'));
    expect(admin, contains('einvoiceMeInvoiceSetupRequired'));
    expect(admin, contains('_meinvoiceJobEventsProvider'));
    expect(admin, contains(".from('meinvoice_job_events')"));
    expect(admin, contains("Key('meinvoice_job_event_history')"));
    expect(admin, contains('einvoiceEventHistory'));
    expect(admin, contains('_meinvoiceSellerConfigsProvider'));
    expect(admin, contains('_openMeInvoiceConfigDialog'));
    expect(admin, contains('admin_upsert_meinvoice_tax_entity_config'));
    expect(admin, contains('admin_release_meinvoice_ready_jobs'));
    expect(admin, contains('_releaseReadyMeInvoiceJobs'));
    expect(admin, contains('einvoiceMeInvoiceReleaseReadyJobs'));
    expect(admin, contains('einvoiceMeInvoiceSettings'));
    expect(admin, contains('admin_retry_meinvoice_job'));
    expect(admin, contains('admin_mark_resolved_meinvoice_job'));
    expect(paymentService, contains(".from('meinvoice_jobs')"));
    expect(statusProvider, contains(".from('meinvoice_jobs')"));
    expect(admin, contains('https://api.meinvoice.vn/api/integration/invoice'));
    expect(statusBadge, contains('MISA'));
    expect(paymentDetail, contains("table: 'meinvoice_jobs'"));
    expect(
      adminOps,
      contains('CREATE OR REPLACE FUNCTION public.admin_retry_meinvoice_job'),
    );
    expect(
      adminOps,
      contains(
        'CREATE OR REPLACE FUNCTION public.admin_mark_resolved_meinvoice_job',
      ),
    );
    expect(adminOps, contains("'meinvoice_jobs'"));
    expect(admin, isNot(contains(".from('einvoice_jobs')")));
    expect(admin, isNot(contains('MISA_MEINVOICE_PASSWORD')));
    expect(admin, isNot(contains("'meinvoice_dispatch_enabled': 'true'")));
    expect(
      admin,
      isNot(
        contains(
          'https://api.meinvoice.vn/api/'
          'v3',
        ),
      ),
    );
    expect(admin, isNot(contains('raw_request')));
    expect(admin, isNot(contains('raw_response')));
    expect(paymentService, isNot(contains(".from('einvoice_jobs')")));
    expect(statusProvider, isNot(contains(".from('einvoice_jobs')")));
  });

  test('readiness RPC exposes MISA blockers without dispatch or secrets', () {
    final sql = readRepoFile(readinessPath);

    expect(
      sql,
      contains('CREATE OR REPLACE FUNCTION public.get_meinvoice_readiness'),
    );
    expect(sql, contains('blocking_reasons'));
    expect(sql, contains('dispatch_disabled'));
    expect(sql, contains('integration_not_active'));
    expect(sql, contains('app_id_missing'));
    expect(sql, contains('invoice_series_missing'));
    expect(sql, contains('meinvoice_dispatch_enabled'));
    expect(sql, contains('public.is_super_admin()'));
    expect(sql, contains('public.user_accessible_stores(auth.uid())'));
    expect(
      sql,
      contains('GRANT EXECUTE ON FUNCTION public.get_meinvoice_readiness()'),
    );
    expect(sql, isNot(contains('cron.schedule')));
    expect(sql, isNot(contains('current_token')));
  });

  test('admin config RPC stores only non-secret MISA seller settings', () {
    final sql = readRepoFile(configAdminPath);

    expect(
      sql,
      contains(
        'CREATE OR REPLACE FUNCTION public.admin_upsert_meinvoice_tax_entity_config',
      ),
    );
    expect(sql, contains('SECURITY DEFINER'));
    expect(
      sql,
      contains("v_actor.role NOT IN ('admin', 'brand_admin', 'super_admin')"),
    );
    expect(sql, contains("einvoice_provider = 'meinvoice'"));
    expect(sql, contains("tax_code <> 'PLACEHOLDER_DEV_000'"));
    expect(sql, contains('p_app_id'));
    expect(sql, contains('p_invoice_series'));
    expect(sql, contains('p_payment_method_cash'));
    expect(sql, contains('p_payment_method_card'));
    expect(sql, contains('p_payment_method_pay'));
    expect(sql, contains('p_payment_method_mixed'));
    expect(sql, contains('MEINVOICE_ACTIVE_CONFIG_INCOMPLETE'));
    expect(sql, contains('DELETE FROM public.meinvoice_token_cache'));
    expect(sql, contains('admin_upsert_meinvoice_tax_entity_config'));
    expect(sql, contains('INSERT INTO public.audit_logs'));
    expect(sql, contains('dispatch_gate_changed'));
    expect(
      sql,
      contains(
        'REVOKE ALL ON FUNCTION public.admin_upsert_meinvoice_tax_entity_config',
      ),
    );
    expect(
      sql,
      contains(
        'GRANT EXECUTE ON FUNCTION public.admin_upsert_meinvoice_tax_entity_config',
      ),
    );
    expect(sql, isNot(contains('cron.schedule')));
    expect(sql, isNot(contains('UPDATE public.system_config')));
    expect(sql, isNot(contains('current_token')));
    expect(sql, isNot(contains('p_username')));
    expect(sql, isNot(contains('p_password')));
  });

  test('admin ready-queue RPC only releases configured jobs to pending', () {
    final sql = readRepoFile(readyQueueAdminPath);

    expect(
      sql,
      contains(
        'CREATE OR REPLACE FUNCTION public.admin_release_meinvoice_ready_jobs',
      ),
    );
    expect(sql, contains('SECURITY DEFINER'));
    expect(
      sql,
      contains(
        "v_actor.role NOT IN ('admin', 'store_admin', 'brand_admin', 'super_admin')",
      ),
    );
    expect(sql, contains("einvoice_provider = 'meinvoice'"));
    expect(sql, contains("tax_code <> 'PLACEHOLDER_DEV_000'"));
    expect(sql, contains("v_config.integration_status <> 'active'"));
    expect(sql, contains('MEINVOICE_RELEASE_CONFIG_INCOMPLETE'));
    expect(
      sql,
      contains("mj.status IN ('pending_manual_config', 'dispatch_paused')"),
    );
    expect(sql, contains('public.user_accessible_stores(auth.uid())'));
    expect(sql, contains('UPDATE public.meinvoice_jobs'));
    expect(sql, contains("SET status = 'pending'"));
    expect(sql, contains('admin_release_meinvoice_ready_jobs'));
    expect(sql, contains('INSERT INTO public.audit_logs'));
    expect(sql, contains('dispatch_gate_changed'));
    expect(
      sql,
      contains(
        'REVOKE ALL ON FUNCTION public.admin_release_meinvoice_ready_jobs',
      ),
    );
    expect(
      sql,
      contains(
        'GRANT EXECUTE ON FUNCTION public.admin_release_meinvoice_ready_jobs',
      ),
    );
    expect(sql, isNot(contains('UPDATE public.system_config')));
    expect(sql, isNot(contains('cron.schedule')));
    expect(sql, isNot(contains('current_token')));
    expect(sql, isNot(contains('p_username')));
    expect(sql, isNot(contains('p_password')));
  });
}
