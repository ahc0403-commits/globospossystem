import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test(
    'inventory admin surface uses the dedicated QSC inventory workspace',
    () {
      final admin = readRepoFile('lib/features/admin/admin_screen.dart');
      final screen = readRepoFile(
        'lib/features/inventory_purchase/inventory_purchase_screen.dart',
      );

      expect(
        admin,
        contains(
          "import '../inventory_purchase/inventory_purchase_screen.dart';",
        ),
      );
      expect(admin, contains('const InventoryPurchaseScreen()'));
      expect(admin, isNot(contains('const InventoryTab()')));
      expect(screen, contains('재고/발주 관리 대시보드'));
      expect(screen, contains('재고 현황'));
      expect(screen, contains('발주 관리'));
      expect(screen, contains('발주 내역'));
      expect(screen, contains('거래처 관리'));
      expect(screen, contains('제품 관리'));
      expect(screen, contains('레시피 관리'));
      expect(screen, contains('소진량 분석'));
      expect(screen, contains('원가 분석'));
      expect(screen, contains('실재고 실사'));
      expect(screen, contains('신메뉴 등록'));
      expect(screen, contains('ToastMetricStrip('));
      expect(
        screen,
        isNot(contains("Key('inventory_purchase_secondary_detail')")),
      );
      expect(screen, isNot(contains('initiallyExpanded: false')));
    },
  );
}
