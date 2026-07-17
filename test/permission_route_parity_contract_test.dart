import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/utils/permission_utils.dart';
import 'package:globos_pos_system/core/utils/role_routes.dart';

void main() {
  test(
    'photo-ops access helper and route guard stay aligned for core roles',
    () {
      const roles = [
        'super_admin',
        'photo_objet_master',
        'photo_objet_store_operator',
        'photo_objet_store_admin',
        'brand_admin',
        'store_admin',
        'admin',
        'waiter',
      ];

      for (final role in roles) {
        expect(
          canAccessRouteForRole(role, '/photo-ops'),
          PermissionUtils.canAccessPhotoOps(role),
          reason: 'photo-ops access drift for role=$role',
        );
      }
    },
  );
}
