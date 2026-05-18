import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test(
    'waiter uses shared floor layout instead of fixed grid table rendering',
    () {
      final floorLayout = readRepoFile('lib/features/table/floor_layout.dart');
      final waiter = readRepoFile('lib/features/waiter/waiter_screen.dart');

      expect(floorLayout, contains('class FloorLayoutView'));
      expect(floorLayout, contains('Positioned('));
      expect(floorLayout, contains('onTableMoved'));
      expect(waiter, contains('FloorLayoutView('));
      expect(waiter, contains('_buildWaiterCommandHeader'));
      expect(waiter, contains('ToastMetricStrip('));
      expect(waiter, isNot(contains('PosPageHeader(')));
      expect(waiter, isNot(contains('PosStatCard(')));
      expect(
        waiter,
        isNot(contains('SliverGridDelegateWithFixedCrossAxisCount')),
      );
    },
  );
}
