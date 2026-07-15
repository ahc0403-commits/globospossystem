import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('create_staff_user rejects inactive callers before role checks', () {
    final source = File(
      'supabase/functions/create_staff_user/index.ts',
    ).readAsStringSync();

    expect(source, contains("brand_id, is_active')"));

    final activeCheck = source.indexOf('callerProfile.is_active !== true');
    final roleCheck = source.indexOf("!['admin', 'store_admin'");

    expect(activeCheck, greaterThan(-1));
    expect(roleCheck, greaterThan(activeCheck));
    expect(
      source.substring(activeCheck, roleCheck),
      allOf(contains("status: 403"), contains('Forbidden: inactive user')),
    );
  });

  test(
    'create_staff_user rejects legacy admin and rolls back post-create failures',
    () {
      final source = File(
        'supabase/functions/create_staff_user/index.ts',
      ).readAsStringSync();

      final supportedRolesStart = source.indexOf('const supportedRoles = [');
      final supportedRolesEnd = source.indexOf(']', supportedRolesStart);
      expect(supportedRolesStart, greaterThan(-1));
      expect(supportedRolesEnd, greaterThan(supportedRolesStart));
      expect(
        source.substring(supportedRolesStart, supportedRolesEnd),
        isNot(contains("'admin'")),
      );

      expect(source, contains('rollbackProvisionedUser'));
      expect(source, contains("if (syncError)"));
      expect(source, contains("if (refreshClaimsError)"));
      expect(source, contains('CLAIMS_POSTCONDITION_FAILED'));
      expect(
        RegExp(r'await rollbackProvisionedUser\(').allMatches(source).length,
        greaterThanOrEqualTo(3),
      );
    },
  );
}
