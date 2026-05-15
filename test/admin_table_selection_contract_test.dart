import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test(
    'admin table selection clears the prior order session before loading a new table',
    () {
      final adminTables = readRepoFile(
        'lib/features/admin/tabs/tables_tab.dart',
      );

      expect(
        adminTables,
        contains('ref.read(orderProvider.notifier).clearSession();'),
      );
      expect(
        adminTables,
        contains(
          'await ref.read(orderProvider.notifier).loadActiveOrder(tableId, storeId);',
        ),
      );
    },
  );

  test(
    'admin tables default detail stays read-only and does not own order payment or kitchen execution',
    () {
      final adminTables = readRepoFile(
        'lib/features/admin/tabs/tables_tab.dart',
      );

      expect(adminTables, contains('_AdminTableOperationsPanel'));
      expect(adminTables, isNot(contains('OrderWorkspace(')));
      expect(adminTables, isNot(contains('showPaymentActions: true')));
      expect(adminTables, isNot(contains('canManageSentItems: true')));
      expect(adminTables, isNot(contains('onCycleSentItemStatus:')));
      expect(adminTables, isNot(contains('onProcessPayment:')));
      expect(
        adminTables,
        isNot(contains("import '../../payment/payment_provider.dart';")),
      );
    },
  );
}
