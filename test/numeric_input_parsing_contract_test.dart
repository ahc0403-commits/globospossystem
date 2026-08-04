import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/utils/number_input_utils.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('operator numeric inputs accept formatted thousands separators', () {
    expect(parseDecimalInput('18,000'), 18000);
    expect(parseDecimalInput(' 1,534,400 '), 1534400);
    expect(parseDecimalInput(''), isNull);
    expect(parseDecimalInput('abc'), isNull);

    expect(parseIntInput('1,000'), 1000);
    expect(parseIntInput(' 12 '), 12);
    expect(parseIntInput(''), isNull);
    expect(parseIntInput('1.5'), isNull);
  });

  test('localized physical quantities preserve decimal commas', () {
    expect(parseLocalizedQuantityInput('0,5'), 0.5);
    expect(parseLocalizedQuantityInput('1,5'), 1.5);
    expect(parseLocalizedQuantityInput('1.5'), 1.5);
    expect(parseLocalizedQuantityInput('1,2345'), isNull);
    expect(parseLocalizedQuantityInput('1,2.3'), isNull);
  });

  test('primary operator forms use comma-tolerant numeric parsing', () {
    final inventoryPurchase = readRepoFile(
      'lib/features/inventory_purchase/inventory_purchase_screen.dart',
    );
    final inventoryLegacy = readRepoFile(
      'lib/features/admin/tabs/inventory_tab.dart',
    );
    final menu = readRepoFile('lib/features/admin/tabs/menu_tab.dart');
    final settings = readRepoFile('lib/features/admin/tabs/settings_tab.dart');
    final onboarding = readRepoFile(
      'lib/features/onboarding/onboarding_screen.dart',
    );
    final superAdmin = readRepoFile(
      'lib/features/super_admin/super_admin_screen.dart',
    );
    final waiter = readRepoFile('lib/features/waiter/waiter_screen.dart');
    final orderWorkspace = readRepoFile('lib/widgets/order_workspace.dart');
    final tables = readRepoFile('lib/features/admin/tabs/tables_tab.dart');
    final qcAdmin = readRepoFile('lib/features/admin/tabs/qc_tab.dart');
    final qcReview = readRepoFile('lib/features/qc/qc_review_screen.dart');
    final photoInventory = readRepoFile(
      'lib/features/photo_inventory/photo_inventory_screen.dart',
    );
    final photoOps = readRepoFile(
      'lib/features/photo_ops/photo_ops_screen.dart',
    );

    expect(
      inventoryPurchase,
      contains('parseDecimalInput(factorController.text)'),
    );
    expect(
      inventoryPurchase,
      contains('parseDecimalInput(unitPriceController.text)'),
    );
    expect(
      inventoryPurchase,
      contains('parseIntInput(leadTimeController.text)'),
    );
    expect(
      inventoryPurchase,
      isNot(contains('double.tryParse(factorController.text.trim())')),
    );

    expect(
      inventoryLegacy,
      contains('parseDecimalInput(actualController.text)'),
    );
    expect(
      inventoryLegacy,
      contains('parseDecimalInput(stockController.text)'),
    );
    expect(menu, contains('parseDecimalInput(priceController.text)'));
    expect(settings, contains('parseDecimalInput(_perPersonController.text)'));
    expect(
      onboarding,
      contains('parseDecimalInput(_perPersonController.text)'),
    );
    expect(superAdmin, contains('parseDecimalInput(chargeController.text)'));
    expect(waiter, contains('parseIntInput(controller.text)'));
    expect(orderWorkspace, contains('parseIntInput(controller.text)'));
    expect(tables, contains('parseIntInput(seatController.text)'));
    expect(qcAdmin, contains('parseIntInput(sortController.text)'));
    expect(qcReview, contains('parseDecimalInput(scoreController.text)'));
    expect(
      photoInventory,
      contains('parseLocalizedQuantityInput(stockController.text)'),
    );
    expect(
      photoOps,
      contains(
        'parseLocalizedQuantityInput(\n                  quantity.text,',
      ),
    );
  });
}
