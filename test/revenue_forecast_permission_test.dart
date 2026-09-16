import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/utils/permission_utils.dart';

void main() {
  test('forecast access is limited to platform owner and BM roles', () {
    expect(PermissionUtils.canAccessRevenueForecast('super_admin'), isTrue);
    expect(PermissionUtils.canAccessRevenueForecast('brand_admin'), isTrue);
    expect(
      PermissionUtils.canAccessRevenueForecast('photo_objet_master'),
      isTrue,
    );

    for (final role in [
      null,
      'admin',
      'store_admin',
      'photo_objet_store_operator',
      'cashier',
    ]) {
      expect(
        PermissionUtils.canAccessRevenueForecast(role),
        isFalse,
        reason: '$role must not access network forecasting',
      );
    }
  });
}
