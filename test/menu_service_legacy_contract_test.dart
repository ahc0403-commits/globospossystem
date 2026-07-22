import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('menu service uses the multilingual admin menu RPC signatures', () {
    final source = readRepoFile('lib/core/services/menu_service.dart');

    expect(source, contains("'admin_create_menu_category_i18n'"));
    expect(source, contains("'admin_create_menu_item_i18n'"));
    expect(source, contains("'p_store_id': storeId"));
    expect(source, contains("'p_name_ko': nameKo"));
    expect(source, contains("'p_name_vi': nameVi"));
    expect(source, contains("'p_name_en': nameEn"));
    expect(source, isNot(contains("'p_restaurant_id': storeId")));
  });
}
