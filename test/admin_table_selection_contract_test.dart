import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('admin table selection clears the prior order session before loading a new table', () {
    final adminTables = readRepoFile('lib/features/admin/tabs/tables_tab.dart');

    expect(adminTables, contains('ref.read(orderProvider.notifier).clearSession();'));
    expect(adminTables, contains('await ref.read(orderProvider.notifier).loadActiveOrder(tableId, storeId);'));
  });
}
