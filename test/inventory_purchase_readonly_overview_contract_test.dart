import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('tracked inventory workspace exposes a read-only purchase overview', () {
    final tab = readRepoFile('lib/features/admin/tabs/inventory_tab.dart');
    final provider = readRepoFile(
      'lib/features/inventory/inventory_provider.dart',
    );
    final service = readRepoFile('lib/core/services/inventory_service.dart');

    expect(tab, contains('Purchase Overview'));
    expect(tab, contains('Purchase Review Detail'));
    expect(tab, contains('Approval Gap'));
    expect(tab, contains('Review Focus'));
    expect(tab, contains('Read-only'));
    expect(tab, contains('inventoryPurchaseOverviewProvider'));
    expect(tab, contains('Refresh Purchase Overview'));

    expect(provider, contains('class InventoryPurchaseOverviewState'));
    expect(provider, contains('inventoryPurchaseOverviewProvider'));

    expect(service, contains('fetchInventoryPurchaseDashboard'));
    expect(service, contains("'get_inventory_purchase_dashboard'"));
    expect(service, isNot(contains('runInventoryPurchaseRecommendation')));
    expect(tab, isNot(contains('run_inventory_purchase_recommendation')));
    expect(tab, isNot(contains('InventoryPurchaseScreen')));
  });
}
