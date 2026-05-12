import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test(
    'tracked inventory workspace exposes a bounded recommendation trigger',
    () {
      final tab = readRepoFile('lib/features/admin/tabs/inventory_tab.dart');
      final provider = readRepoFile(
        'lib/features/inventory/inventory_provider.dart',
      );
      final service = readRepoFile('lib/core/services/inventory_service.dart');

      expect(tab, contains('Purchase Overview'));
      expect(tab, contains('Purchase Review Detail'));
      expect(tab, contains('Approval Gap'));
      expect(tab, contains('Review Focus'));
      expect(tab, contains('Inventory Recommendation Trigger'));
      expect(tab, contains('Generate Recommendation Snapshot'));
      expect(tab, contains('Recommendation Status'));
      expect(tab, contains('inventoryPurchaseOverviewProvider'));
      expect(tab, contains('inventoryPurchaseRecommendationRunProvider'));
      expect(tab, contains('Refresh Purchase Overview'));

      expect(provider, contains('class InventoryPurchaseOverviewState'));
      expect(provider, contains('inventoryPurchaseOverviewProvider'));
      expect(
        provider,
        contains('class InventoryPurchaseRecommendationRunState'),
      );
      expect(provider, contains('inventoryPurchaseRecommendationRunProvider'));

      expect(service, contains('fetchInventoryPurchaseDashboard'));
      expect(service, contains("'get_inventory_purchase_dashboard'"));
      expect(service, contains('runInventoryPurchaseRecommendation'));
      expect(service, contains("'run_inventory_purchase_recommendation'"));
      expect(
        tab,
        contains(
          'This slice may create a recommendation snapshot, but it still does not create purchase orders or mutate stock.',
        ),
      );
      expect(
        tab,
        isNot(contains('create_purchase_orders_from_recommendation')),
      );
      expect(tab, isNot(contains('InventoryPurchaseScreen')));
    },
  );
}
