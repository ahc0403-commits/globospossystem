import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'helpers/production_gate_test_support.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  test('supplier banking and ingredient Excel are end-to-end wired', () {
    final screen = _read(
      'lib/features/inventory_purchase/inventory_purchase_screen.dart',
    );
    final service = _read('lib/core/services/inventory_service.dart');
    final provider = _read('lib/features/inventory/inventory_provider.dart');
    final migration = _read(
      'supabase/migrations/20260727013210_inventory_ingredient_excel_supplier_banking.sql',
    );

    expect(screen, contains('inventory_supplier_bank_name_field'));
    expect(screen, contains('inventory_supplier_bank_account_holder_field'));
    expect(screen, contains('inventory_ingredient_template_download_action'));
    expect(screen, contains('inventory_ingredient_excel_import_action'));
    expect(screen, contains('buildIngredientImportTemplate'));
    expect(screen, contains('parseIngredientImportWorkbook'));
    expect(service, contains("'p_bank_name': bankName"));
    expect(service, contains("'p_bank_account_holder': bankAccountHolder"));
    expect(service, contains("'bulk_upsert_inventory_ingredients'"));
    expect(provider, contains('bulkUpsertIngredients'));
    expect(migration, contains('ADD COLUMN IF NOT EXISTS bank_name'));
    expect(migration, contains('ADD COLUMN IF NOT EXISTS bank_account_holder'));
    expect(migration, contains('bulk_upsert_inventory_ingredients'));
    expect(
      migration,
      contains('Validate every row before performing any mutation'),
    );
  });

  test('recipe access uses accessible-store scope and buttons remain usable', () {
    final screen = _read(
      'lib/features/inventory_purchase/inventory_purchase_screen.dart',
    );
    final migration = _read(
      'supabase/migrations/20260727013210_inventory_ingredient_excel_supplier_banking.sql',
    );
    final ko = _read('lib/l10n/app_ko.arb');

    expect(
      migration,
      contains('can_access_inventory_purchase_store(p_store_id)'),
    );
    expect(
      screen,
      isNot(
        contains(
          'recipeState.menuItems.isEmpty || productCatalog.products.isEmpty\n'
          '              ? null\n'
          '              : () => _downloadRecipeTemplate',
        ),
      ),
    );
    expect(ko, contains('"inventoryPurchaseProductManagementTitle": "원재료 관리"'));
    expect(ko, contains('"inventoryPurchaseIngredientExcelImport"'));
  });

  test('production migration gate has preflight and verification', () {
    final deploy = readProductionGateContract();
    expect(
      deploy,
      contains(
        '20260727013210_inventory_ingredient_excel_supplier_banking.sql',
      ),
    );
    expect(
      deploy,
      contains('preflight_inventory_ingredient_excel_supplier_banking.sql'),
    );
    expect(
      deploy,
      contains('verify_inventory_ingredient_excel_supplier_banking.sql'),
    );
  });
}
