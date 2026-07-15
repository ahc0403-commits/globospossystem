import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const migrationPath =
    'supabase/migrations/20260715020000_security_expand_compat.sql';

void main() {
  late String migration;

  setUpAll(() {
    migration = File(migrationPath).readAsStringSync();
  });

  test('payment retries use an atomic server-side idempotency ledger', () {
    final service = File(
      'lib/core/services/payment_service.dart',
    ).readAsStringSync();
    final provider = File(
      'lib/features/payment/payment_provider.dart',
    ).readAsStringSync();

    expect(
      migration,
      contains('CREATE TABLE IF NOT EXISTS public.payment_attempts'),
    );
    expect(
      migration,
      contains(
        'CREATE UNIQUE INDEX IF NOT EXISTS payment_attempts_order_attempt_uidx',
      ),
    );
    expect(migration, contains('pg_advisory_xact_lock'));
    expect(migration, contains('PAYMENT_ATTEMPT_MISMATCH'));
    expect(
      migration,
      contains(
        'CREATE OR REPLACE FUNCTION public.process_payment(\n'
        '  p_order_id uuid,\n'
        '  p_store_id uuid,\n'
        '  p_amount numeric,\n'
        '  p_method text,\n'
        '  p_payment_attempt_id uuid',
      ),
    );
    expect(
      migration,
      contains(
        'GRANT EXECUTE ON FUNCTION public.process_payment(uuid, uuid, numeric, text) '
        'TO authenticated, service_role;',
      ),
    );
    expect(service, contains("'p_payment_attempt_id': paymentAttemptId"));
    expect(service, contains('attemptStore.getOrCreate'));
    expect(provider, contains('processPaymentWithPersistentAttempt'));
  });

  test('payment proof stores object paths and never durable bearer URLs', () {
    final service = File(
      'lib/core/services/payment_proof_service.dart',
    ).readAsStringSync();

    expect(service, isNot(contains('createSignedUrl')));
    expect(service, isNot(contains('_persistQueueFile')));
    expect(service, isNot(contains('originalFile.copy')));
    expect(service, contains('remaining.add(rawItem)'));
    expect(service, contains('await uploadAndAttach('));
    expect(service, contains('await file.delete()'));
    expect(
      service.indexOf('await uploadAndAttach('),
      lessThan(service.indexOf('await file.delete()')),
    );
    expect(service, contains("'p_proof_object_path': path"));
    expect(migration, contains('p_proof_object_path text'));
    expect(
      migration,
      isNot(contains("'proof_photo_url', p_proof_object_path")),
    );
    expect(migration, contains("'proof_object_path', p_proof_object_path"));
  });

  test(
    'payroll PIN is verified server-side with rate limiting and hidden hash',
    () {
      final pinService = File(
        'lib/core/services/pin_service.dart',
      ).readAsStringSync();
      final attendanceTab = File(
        'lib/features/admin/tabs/attendance_tab.dart',
      ).readAsStringSync();

      expect(pinService, isNot(contains("select('payroll_pin')")));
      expect(pinService, isNot(contains('sha256')));
      expect(pinService, contains("'get_payroll_pin_status'"));
      expect(pinService, contains("'verify_payroll_pin'"));
      expect(
        migration,
        contains('CREATE TABLE IF NOT EXISTS public.payroll_pin_rate_limits'),
      );
      expect(
        migration,
        contains('extensions.crypt(p_pin, v_bcrypt_hash)'),
      );
      expect(migration, contains("extensions.gen_salt('bf'"));
      expect(migration, contains("extensions.digest(p_pin, 'sha256')"));
      expect(migration, contains('PAYROLL_PIN_RATE_LIMITED'));
      expect(
        attendanceTab,
        contains('_hasPayrollPin != false && !_payrollUnlocked'),
      );
      expect(attendanceTab, contains('if (!payrollRequiresUnlock)'));
      expect(
        attendanceTab,
        contains('Unable to verify the payroll PIN. Try again.'),
      );
      expect(pinService, contains("'set_payroll_pin_v2'"));
      expect(pinService, contains("'clear_payroll_pin_v2'"));
      expect(migration, contains('payroll_pin_verifier text'));
      expect(migration, isNot(contains('NULL::text AS payroll_pin')));
    },
  );

  test('all Edge Supabase imports are exact pinned versions', () {
    final functionFiles = Directory('supabase/functions')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.ts'));

    for (final file in functionFiles) {
      final source = file.readAsStringSync();
      for (final match in RegExp(
        r'''https://esm\.sh/@supabase/supabase-js@([^'\"]+)''',
      ).allMatches(source)) {
        expect(match.group(1), '2.110.2', reason: file.path);
      }
    }
  });

  test('bulk password reset utility is quarantined from Auth mutations', () {
    final source = File(
      'scripts/reset_all_auth_passwords.js',
    ).readAsStringSync();
    expect(source, contains('BULK_AUTH_PASSWORD_RESET_DISABLED'));
    expect(source, isNot(contains('updateUserById')));
    expect(source, isNot(contains('listUsers')));
    expect(source, isNot(contains('NEW_PASSWORD')));
  });
}
