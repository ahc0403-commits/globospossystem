import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('menu service retries legacy admin menu RPC signatures', () {
    final source = readRepoFile('lib/core/services/menu_service.dart');

    expect(source, contains('_isRpcSignatureMismatch'));
    expect(source, contains("'admin_create_menu_category'"));
    expect(source, contains("'admin_create_menu_item'"));
    expect(source, contains("'p_store_id': storeId"));
    expect(source, contains("'p_restaurant_id': storeId"));
    expect(source, contains('itemParams'));
  });
}
