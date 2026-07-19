import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/auth/auth_state.dart';
import 'package:globos_pos_system/features/auth/initial_password_change_screen.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('auth state preserves and clears the first-login password gate', () {
    const pending = PosAuthState(
      passwordChangeRequired: true,
      isPasswordChangeSubmitting: true,
      privacyConsentRequired: true,
    );

    final completed = pending.copyWith(
      passwordChangeRequired: false,
      isPasswordChangeSubmitting: false,
    );
    expect(completed.passwordChangeRequired, isFalse);
    expect(completed.isPasswordChangeSubmitting, isFalse);
    expect(completed.privacyConsentRequired, isTrue);

    final signedOut = pending.copyWith(clearUser: true);
    expect(signedOut.passwordChangeRequired, isFalse);
    expect(signedOut.isPasswordChangeSubmitting, isFalse);
  });

  test('new password policy requires all server-approved categories', () {
    expect(isStrongInitialPassword('Short1!'), isFalse);
    expect(isStrongInitialPassword('lowercaseonly1!'), isFalse);
    expect(isStrongInitialPassword('UPPERCASEONLY1!'), isFalse);
    expect(isStrongInitialPassword('NoNumberHere!'), isFalse);
    expect(isStrongInitialPassword('NoSymbolHere12'), isFalse);
    expect(isStrongInitialPassword('SecureShift12!'), isTrue);
  });

  test('router makes password change precede consent and every POS route', () {
    final router = readRepoFile('lib/core/router/app_router.dart');
    final passwordGate = router.indexOf('auth.passwordChangeRequired');
    final consentGate = router.indexOf('auth.privacyConsentRequired');

    expect(passwordGate, greaterThan(0));
    expect(consentGate, greaterThan(passwordGate));
    expect(router, contains("path: '/change-initial-password'"));
    expect(router, contains('InitialPasswordChangeScreen'));
    expect(router, contains("location == '/change-initial-password'"));
  });

  test('database arms every Auth password write and advances its generation', () {
    final sql = readRepoFile(
      'supabase/migrations/20260719140000_password_change_lifecycle_fail_closed.sql',
    );

    expect(
      sql,
      contains('password_change_generation bigint NOT NULL DEFAULT 0'),
    );
    expect(sql, contains('AFTER UPDATE OF encrypted_password ON auth.users'));
    expect(sql, contains('SET must_change_password = true'));
    expect(
      sql,
      contains('password_change_generation = password_change_generation + 1'),
    );
    expect(sql, isNot(contains('SET must_change_password = false')));
    expect(
      sql,
      contains('REVOKE UPDATE ON public.users FROM anon, authenticated'),
    );
  });

  test(
    'authenticated Edge flow is the only client password completion path',
    () {
      final provider = readRepoFile('lib/features/auth/auth_provider.dart');
      final function = readRepoFile(
        'supabase/functions/complete-initial-password-change/index.ts',
      );

      expect(provider, contains("'complete-initial-password-change'"));
      expect(provider, isNot(contains('supabase.auth.updateUser')));
      expect(function, contains('callerClient.auth.getUser()'));
      expect(function, contains('serviceClient.auth.admin.updateUserById'));
      expect(function, contains('profile.generation + 1'));
      expect(function, contains('password_change_generation'));
      expect(function, isNot(contains('body.user_id')));
    },
  );

  test('admin password rotation restores the first-login requirement', () {
    final function = readRepoFile(
      'supabase/functions/provision-fixed-pos-account/index.ts',
    );

    expect(function, contains('if (rotatePassword)'));
    expect(function, contains('must_change_password: true'));
    expect(function, contains('password_change_required_at'));
    expect(function, contains('PASSWORD_CHANGE_GATE_REARM_FAILED'));
  });
}
