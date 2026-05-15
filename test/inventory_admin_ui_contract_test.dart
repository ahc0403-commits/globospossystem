import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('inventory admin surface stays compact and operational', () {
    final source = readRepoFile('lib/features/admin/tabs/inventory_tab.dart');

    expect(source, contains('_buildInventoryCommandHeader'));
    expect(source, contains('ToastMetricStrip('));
    expect(source, contains("Key('inventory_purchase_secondary_detail')"));
    expect(source, contains('initiallyExpanded: false'));
    expect(
      source,
      isNot(
        contains(
          'OutlinedButton.icon(\n                  onPressed: storeId == null',
        ),
      ),
    );
  });
}
