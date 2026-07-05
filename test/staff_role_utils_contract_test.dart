import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/utils/staff_role_utils.dart';

void main() {
  group('assignableRolesForViewer', () {
    test('does not offer legacy admin for new staff creation', () {
      for (final viewerRole in [
        null,
        'super_admin',
        'brand_admin',
        'store_admin',
        'admin',
      ]) {
        expect(
          assignableRolesForViewer(viewerRole),
          isNot(contains('admin')),
          reason:
              'legacy admin must remain display-only for viewer=$viewerRole',
        );
      }
    });

    test('keeps authoritative admin hierarchy assignable', () {
      expect(
        assignableRolesForViewer('super_admin'),
        containsAll(['store_admin', 'brand_admin']),
      );
      expect(assignableRolesForViewer('brand_admin'), contains('store_admin'));
      expect(
        assignableRolesForViewer('store_admin'),
        equals(['waiter', 'kitchen', 'cashier']),
      );
    });

    test('keeps legacy admin rows non-editable for extra permissions', () {
      expect(canManageExtraPermissions('admin'), isFalse);
      expect(roleDisplayName('admin'), 'Admin');
    });
  });

  test('create_staff_user rejects new legacy admin role', () {
    final source = File(
      'supabase/functions/create_staff_user/index.ts',
    ).readAsStringSync();
    final supportedRoles = RegExp(
      r'const supportedRoles = \[(.*?)\]',
      dotAll: true,
    ).firstMatch(source)?.group(1);

    expect(supportedRoles, isNotNull);
    expect(supportedRoles, isNot(contains("'admin'")));
    expect(supportedRoles, contains("'store_admin'"));
    expect(supportedRoles, contains("'brand_admin'"));
  });
}
