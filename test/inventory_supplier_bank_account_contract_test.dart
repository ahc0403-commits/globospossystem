import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  test('supplier bank account is persisted and exposed in the POS UI', () {
    final screen = _read(
      'lib/features/inventory_purchase/inventory_purchase_screen.dart',
    );
    final provider = _read('lib/features/inventory/inventory_provider.dart');
    final service = _read('lib/core/services/inventory_service.dart');
    final migration = _read(
      'supabase/migrations/20260723020000_inventory_supplier_bank_account.sql',
    );
    final verification = _read(
      'scripts/verify_inventory_supplier_bank_account.sql',
    );
    final deploy = _read('scripts/deploy_pos_production.sh');

    expect(screen, contains("Key('inventory_supplier_bank_account_field')"));
    expect(screen, contains("supplier?['bank_account_number']"));
    expect(screen, contains('bankAccountNumber: _nullableText('));
    expect(provider, contains('String? bankAccountNumber'));
    expect(service, contains("'p_bank_account_number': bankAccountNumber"));
    expect(service, contains('bank_account_number, payment_terms'));
    expect(migration, contains('ADD COLUMN IF NOT EXISTS bank_account_number'));
    expect(migration, contains('p_bank_account_number text DEFAULT NULL'));
    expect(verification, contains('SUPPLIER_BANK_ACCOUNT_VERIFY_RPC_MISSING'));
    expect(
      deploy,
      contains('20260723020000_inventory_supplier_bank_account.sql'),
    );
    expect(deploy, contains('verify_inventory_supplier_bank_account.sql'));
  });

  test('supplier bank account label is localized', () {
    expect(
      _read('lib/l10n/app_en.arb'),
      contains('"inventoryPurchaseBankAccountNumber"'),
    );
    expect(
      _read('lib/l10n/app_ko.arb'),
      contains('"inventoryPurchaseBankAccountNumber": "계좌번호"'),
    );
    expect(
      _read('lib/l10n/app_vi.arb'),
      contains(
        '"inventoryPurchaseBankAccountNumber": "Số tài khoản ngân hàng"',
      ),
    );
  });
}
