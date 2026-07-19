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

  test(
    'database owns and clears the gate only after Auth hash replacement',
    () {
      final sql = readRepoFile(
        'supabase/migrations/20260719020000_force_initial_password_change.sql',
      );

      expect(
        sql,
        contains('must_change_password boolean NOT NULL DEFAULT true'),
      );
      expect(sql, contains('AFTER UPDATE OF encrypted_password ON auth.users'));
      expect(
        sql,
        contains(
          'OLD.encrypted_password IS DISTINCT FROM NEW.encrypted_password',
        ),
      );
      expect(sql, contains('SET must_change_password = false'));
      expect(
        sql,
        contains('REVOKE UPDATE ON public.users FROM anon, authenticated'),
      );
    },
  );

  test('admin password rotation restores the first-login requirement', () {
    final function = readRepoFile(
      'supabase/functions/provision-fixed-pos-account/index.ts',
    );

    expect(function, contains('if (rotatePassword)'));
    expect(function, contains('must_change_password: true'));
    expect(function, contains('password_change_required_at'));
  });
}
