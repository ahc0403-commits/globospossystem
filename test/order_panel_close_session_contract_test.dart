import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('closing waiter and admin order panels clears the full order session', () {
    final waiter = readRepoFile('lib/features/waiter/waiter_screen.dart');
    final adminTables = readRepoFile('lib/features/admin/tabs/tables_tab.dart');

    expect(waiter, contains('ref.read(orderProvider.notifier).clearSession();'));
    expect(adminTables, contains('ref.read(orderProvider.notifier).clearSession();'));
  });
}
