import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/utils/live_sync_scope.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('operational live sync stays on the selected active store', () {
    final scope = LiveSyncScope(
      role: 'brand_admin',
      activeStoreId: 'store-a',
      accessibleStores: const [
        LiveSyncStore(id: 'store-a', brandId: 'brand-1'),
        LiveSyncStore(id: 'store-b', brandId: 'brand-1'),
        LiveSyncStore(id: 'store-c', brandId: 'brand-2'),
      ],
    );

    expect(scope.operationalStoreIds, ['store-a']);
    expect(scope.activeBrandStoreIds, ['store-a', 'store-b']);
    expect(scope.canSyncStore('store-a'), isTrue);
    expect(scope.canSyncStore('store-b'), isFalse);
    expect(
      scope.canSyncStore('store-b', mode: LiveSyncScopeMode.brandDashboard),
      isTrue,
    );
    expect(
      scope.canSyncStore('store-c', mode: LiveSyncScopeMode.brandDashboard),
      isFalse,
    );
  });

  test('store realtime channels and filters are explicit', () {
    expect(
      LiveSyncScope.storeChannel('cashier_orders', 'store-a'),
      'public:cashier_orders:store-a',
    );
    expect(
      LiveSyncScope.entityChannel('payment_detail', 'store-a', 'payment-a'),
      'public:payment_detail:store-a:payment-a',
    );
    expect(
      LiveSyncScope.storeFilter('store-a').toString(),
      'restaurant_id=eq.store-a',
    );
    expect(
      LiveSyncScope.entityFilter('order_id', 'order-a').toString(),
      'order_id=eq.order-a',
    );
  });

  test(
    'operational providers use scoped channel helpers and store filters',
    () {
      final kitchen = readRepoFile(
        'lib/features/kitchen/kitchen_provider.dart',
      );
      final cashier = readRepoFile(
        'lib/features/payment/payment_provider.dart',
      );
      final waiterTables = readRepoFile(
        'lib/features/table/table_provider.dart',
      );
      final waiterOrder = readRepoFile(
        'lib/features/order/order_provider.dart',
      );
      final adminTables = readRepoFile(
        'lib/features/admin/providers/tables_provider.dart',
      );
      final paymentDetail = readRepoFile(
        'lib/features/payment/payment_detail_screen.dart',
      );

      for (final source in [kitchen, cashier, waiterTables, waiterOrder]) {
        expect(
          source,
          contains("import '../../core/utils/live_sync_scope.dart';"),
        );
        expect(source, contains('LiveSyncScope.storeFilter(storeId)'));
      }

      expect(
        adminTables,
        contains("import '../../../core/utils/live_sync_scope.dart';"),
      );
      expect(
        paymentDetail,
        contains("import '../../core/utils/live_sync_scope.dart';"),
      );
      expect(
        paymentDetail,
        contains("LiveSyncScope.entityFilter('id', widget.paymentId)"),
      );
      expect(
        paymentDetail,
        contains("LiveSyncScope.entityFilter('order_id', orderId)"),
      );
    },
  );
}
