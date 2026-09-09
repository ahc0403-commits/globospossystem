import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const migrationPath =
    'supabase/migrations/'
    '20260909110000_qualify_inventory_purchase_approval_digest.sql';
const receiptAttemptMigrationPath =
    'supabase/migrations/'
    '20260909120000_restore_inventory_receipt_confirmation_attempts.sql';
const purchaseDetailMigrationPath =
    'supabase/migrations/'
    '20260909130000_add_supplier_name_to_inventory_purchase_detail.sql';
const verificationPath = 'scripts/verify_inventory_purchase_approval.sql';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test(
    'brand approval qualifies pgcrypto digest without widening search_path',
    () {
      final migration = readRepoFile(migrationPath);

      expect(
        migration,
        contains('public.brand_decide_inventory_purchase_order('),
      );
      expect(migration, contains('SET search_path = public, auth'));
      expect(
        migration,
        contains(
          "extensions.digest(convert_to(v_snapshot::text, 'UTF8'), 'sha256')",
        ),
      );
      expect(
        migration,
        isNot(contains('search_path = public, auth, extensions')),
      );
      expect(
        migration,
        contains('INVENTORY_PURCHASE_DIGEST_NOT_SCHEMA_QUALIFIED'),
      );
    },
  );

  test('runtime verification enforces the qualified digest definition', () {
    final verification = readRepoFile(verificationPath);

    expect(
      verification,
      contains("v_brand_definition NOT LIKE '%extensions.digest(convert_to(%'"),
    );
  });

  test('receipt verification restores its idempotency attempt table', () {
    final migration = readRepoFile(receiptAttemptMigrationPath);
    final verification = readRepoFile(verificationPath);

    expect(
      migration,
      contains(
        'CREATE TABLE IF NOT EXISTS '
        'public.inventory_receipt_confirmation_attempts',
      ),
    );
    expect(migration, contains('UNIQUE (purchase_order_id, attempt_key)'));
    expect(migration, contains("('succeeded', 'replayed', 'noop')"));
    expect(migration, contains('ENABLE ROW LEVEL SECURITY'));
    expect(migration, contains('inventory_receipt_attempts_scoped_read'));
    expect(
      verification,
      contains("'public.inventory_receipt_confirmation_attempts'"),
    );
    expect(
      verification,
      contains('INVENTORY_RECEIPT_ATTEMPT_IDEMPOTENCY_INVALID'),
    );
  });

  test('Office purchase detail includes the supplier name', () {
    final migration = readRepoFile(purchaseDetailMigrationPath);

    expect(
      migration,
      contains('public.office_get_inventory_purchase_order_detail('),
    );
    expect(migration, contains('supplier.supplier_name'));
    expect(migration, contains("to_jsonb(v_order) || jsonb_build_object("));
    expect(migration, contains("'supplier_name',"));
    expect(
      migration,
      contains('INVENTORY_PURCHASE_DETAIL_SUPPLIER_NAME_MISSING'),
    );
  });
}
