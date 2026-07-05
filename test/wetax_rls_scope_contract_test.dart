import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test(
    'wetax read policies use accessible store scope without tax-axis shortcut',
    () {
      final sql = readRepoFile(
        'supabase/migrations/298_wetax_store_final_read_rls.sql',
      );

      expect(sql, contains('CREATE POLICY "b2b_buyer_cache_store_select"'));
      expect(sql, contains('CREATE POLICY "einvoice_jobs_admin_read"'));
      expect(sql, contains('CREATE POLICY "einvoice_events_admin_read"'));
      expect(
        sql,
        contains('CREATE OR REPLACE FUNCTION public.can_access_einvoice_job('),
      );
      expect(sql, contains('FROM public.user_accessible_stores(auth.uid())'));
      expect(sql, contains('public.can_access_einvoice_job(einvoice_jobs.id)'));
      expect(
        sql,
        contains('public.can_access_einvoice_job(einvoice_events.job_id)'),
      );
      expect(sql, isNot(contains('tax_entity_id = get_user_tax_entity_id()')));
      expect(sql, isNot(contains('job_id IS NULL')));
      expect(sql, isNot(contains('store_id = get_user_store_id()')));
    },
  );

  test(
    'active Flutter reads use meInvoice while reports keep legacy audit',
    () {
      final einvoiceTab = readRepoFile(
        'lib/features/admin/tabs/einvoice_tab.dart',
      );
      final reportProvider = readRepoFile(
        'lib/features/report/report_provider.dart',
      );
      final paymentService = readRepoFile(
        'lib/core/services/payment_service.dart',
      );
      final statusProvider = readRepoFile(
        'lib/features/payment/einvoice_provider.dart',
      );

      expect(einvoiceTab, contains(".from('meinvoice_jobs')"));
      expect(paymentService, contains(".from('meinvoice_jobs')"));
      expect(statusProvider, contains(".from('meinvoice_jobs')"));
      expect(reportProvider, contains(".from('einvoice_jobs')"));
    },
  );

  test(
    'sql smoke test covers sibling-store denial and multi-store allowance',
    () {
      final sql = readRepoFile('test/sql/wetax_rls_scope_smoke.sql');

      expect(
        sql,
        contains(
          'store_admin unexpectedly read sibling-store einvoice_job via shared tax_entity',
        ),
      );
      expect(
        sql,
        contains('brand_admin should read 2 accessible-store einvoice_jobs'),
      );
      expect(
        sql,
        contains(
          'brand_admin unexpectedly read non-accessible store C einvoice_job',
        ),
      );
    },
  );
}
