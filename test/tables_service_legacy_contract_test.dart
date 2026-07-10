import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('tables service falls back when layout columns are absent', () {
    final source = readRepoFile('lib/core/services/tables_service.dart');

    expect(source, contains("_fetchTablesWithLayout"));
    expect(source, contains("message.contains('layout_sort_order')"));
    expect(source, contains("message.contains('is_occupied')"));
    expect(
      source,
      contains(
        "'id,restaurant_id,table_number,status,seat_count,created_at,updated_at'",
      ),
    );
    expect(source, contains("row['is_occupied']"));
    expect(source, contains("row['layout_sort_order'] ??= 0"));
  });

  test('tables service retries legacy admin table RPC signatures', () {
    final source = readRepoFile('lib/core/services/tables_service.dart');

    expect(source, contains('_isRpcSignatureMismatch'));
    expect(source, contains("'admin_create_table'"));
    expect(source, contains("'admin_delete_table'"));
    expect(source, contains("'admin_update_table'"));
    expect(source, contains("'p_restaurant_id': storeId"));
    expect(source, contains("params: {'p_table_id': tableId}"));
    expect(source, contains("'p_status': status"));
    expect(source, contains('legacyLayoutParams'));
  });
}
