import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/utils/permission_utils.dart';
import 'package:globos_pos_system/core/utils/photo_objet_utils.dart';

void main() {
  test('Photo Objet context is detected by role or overridden store brand', () {
    expect(
      PermissionUtils.isPhotoObjetContext(role: 'photo_objet_master'),
      isTrue,
    );
    expect(
      PermissionUtils.isPhotoObjetContext(
        role: 'super_admin',
        brandId: photoObjetBrandId,
      ),
      isTrue,
    );
    expect(
      PermissionUtils.isPhotoObjetContext(
        role: 'super_admin',
        brandId: 'bunsik-brand',
      ),
      isFalse,
    );
  });

  test(
    'Photo Objet admin navigation omits F&B-only tabs and sidebar items',
    () {
      final source = File(
        'lib/features/admin/admin_screen.dart',
      ).readAsStringSync();

      expect(source, contains('if (!isPhotoObjetContext) ...['));
      expect(source, contains('if (!isPhotoObjetContext) const QcTab()'));
      expect(source, contains('const PhotoInventoryScreen()'));
      expect(source, contains('const InventoryPurchaseScreen()'));
      expect(source, contains(".select('brand_id')"));
      expect(
        source,
        contains('if (!isPhotoObjetContext)\n        ToastSidebarItem('),
      );
    },
  );
}
