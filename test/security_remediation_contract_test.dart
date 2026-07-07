import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  group('security remediation contracts', () {
    test('WeTax cron functions fail closed when CRON_SECRET is missing', () {
      const paths = [
        'supabase/functions/wetax-daily-close/index.ts',
        'supabase/functions/wetax-dispatcher/index.ts',
        'supabase/functions/wetax-poller/index.ts',
      ];

      for (final path in paths) {
        final content = readRepoFile(path);
        expect(content, contains('if (!cronSecret)'));
        expect(content, contains('CRON_SECRET not configured'));
        expect(content, contains('status: 503'));
        expect(content, isNot(contains('cronSecret &&')));
      }
    });

    test(
      'WeTax onboarding keeps company lookup for cashier but restricts mutations',
      () {
        final content = readRepoFile(
          'supabase/functions/wetax-onboarding/index.ts',
        );

        expect(
          content,
          contains(
            "const USER_ALLOWED_OPERATIONS = new Set([\"company_lookup\"])",
          ),
        );
        expect(content, contains('const ADMIN_ALLOWED_OPERATIONS = new Set'));
        expect(content, contains('"seller_register"'));
        expect(content, contains('"shops_register"'));
        expect(content, contains('"seller_info"'));
        expect(
          content,
          contains(
            '["admin", "store_admin", "brand_admin", "super_admin"].includes(role)',
          ),
        );
        expect(content, contains('actorCanAccessTaxEntity'));
        expect(content, contains('user_accessible_tax_entities'));
        expect(
          content,
          contains('operation === "commons_refresh" && cronSecret'),
        );
      },
    );

    test('migration adds active-state checks to POS and Office helpers', () {
      final migration = readRepoFile(
        'supabase/migrations/300_security_remediation_minimal.sql',
      );

      expect(
        migration,
        contains('CREATE OR REPLACE FUNCTION public.get_user_restaurant_id()'),
      );
      expect(
        migration,
        contains(
          'CREATE OR REPLACE FUNCTION public.has_any_role(required_roles text[])',
        ),
      );
      expect(
        migration,
        contains('CREATE OR REPLACE FUNCTION public.is_super_admin()'),
      );
      expect(
        migration,
        contains('CREATE OR REPLACE FUNCTION public.is_photo_objet_master()'),
      );
      expect(
        migration,
        contains(
          'CREATE OR REPLACE FUNCTION public.get_photo_objet_store_id()',
        ),
      );
      expect(migration, contains('AND is_active = TRUE'));
      expect(migration, contains('AND oup.is_active = TRUE'));
    });

    test('payment proof evidence is append-only for normal cashier upload', () {
      final service = readRepoFile(
        'lib/core/services/payment_proof_service.dart',
      );
      final migration = readRepoFile(
        'supabase/migrations/300_security_remediation_minimal.sql',
      );

      expect(service, contains(r'$paymentId/$objectId.jpg'));
      expect(service, contains('upsert: false'));
      expect(
        migration,
        contains('CREATE POLICY storage_payment_proofs_insert'),
      );
      expect(
        migration,
        contains('CREATE POLICY storage_payment_proofs_update_admin'),
      );
      expect(
        migration,
        contains('CREATE POLICY storage_payment_proofs_delete_admin'),
      );
      expect(migration, contains('PAYMENT_PROOF_PATH_INVALID'));
      expect(migration, contains('/storage/v1/object/sign/payment-proofs/%/'));
    });

    test('sensitive reads are scoped server-side', () {
      final migration = readRepoFile(
        'supabase/migrations/300_security_remediation_minimal.sql',
      );

      expect(
        migration,
        contains('DROP POLICY IF EXISTS "authenticated_access_qc_photos"'),
      );
      expect(
        migration,
        contains('CREATE POLICY staff_wage_configs_payroll_read'),
      );
      expect(
        migration,
        contains(
          'DROP POLICY IF EXISTS "inventory_supplier_items_authenticated_read"',
        ),
      );
      expect(
        migration,
        contains(
          'DROP POLICY IF EXISTS "inventory_suppliers_authenticated_read"',
        ),
      );
      expect(
        migration,
        contains('CREATE POLICY inventory_supplier_items_store_read'),
      );
      expect(
        migration,
        contains('CREATE POLICY inventory_suppliers_store_read'),
      );
      expect(
        migration,
        contains(
          "v_actor.role NOT IN ('cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin')",
        ),
      );
    });

    test('recalc_order_status is no longer client executable', () {
      final migration = readRepoFile(
        'supabase/migrations/20260708000000_recalc_order_status_acl_closure.sql',
      );

      expect(
        migration,
        contains('REVOKE EXECUTE ON FUNCTION public.recalc_order_status(uuid)'),
      );
      expect(migration, contains('FROM PUBLIC, anon, authenticated'));
      expect(
        migration,
        contains('GRANT EXECUTE ON FUNCTION public.recalc_order_status(uuid)'),
      );
      expect(migration, contains('TO service_role'));
      expect(migration, isNot(contains('TO authenticated')));
      expect(migration, isNot(contains('TO anon')));
    });
  });
}
