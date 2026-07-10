import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late String migrationContent;

  setUpAll(() {
    final file = File(
      'supabase/migrations/20260610000003_rotate_cron_secret_to_vault.sql',
    );
    expect(file.existsSync(), isTrue);
    migrationContent = file.readAsStringSync();
  });

  group('CRON_SECRET rotation migration', () {
    test('does not contain the leaked secret value in executable code', () {
      final executableLines = migrationContent
          .split('\n')
          .where((line) => !line.trimLeft().startsWith('--'))
          .join('\n');
      expect(
        executableLines,
        isNot(contains('8689bac6')),
        reason: 'Must not hardcode the old (or any) secret value in executable code',
      );
    });

    test('reads secret from vault.decrypted_secrets', () {
      expect(
        migrationContent,
        contains('vault.decrypted_secrets'),
        reason: 'Must read the bearer token from Vault at runtime',
      );
    });

    test('unschedules all 4 WeTax cron jobs', () {
      const jobs = [
        'wetax-dispatcher-every-minute',
        'wetax-poller-every-2-minutes',
        'wetax-daily-close-00-hcmc',
        'wetax-commons-refresh-weekly',
      ];
      for (final job in jobs) {
        expect(
          migrationContent,
          contains("cron.unschedule('$job')"),
          reason: 'Must unschedule $job before rescheduling',
        );
      }
    });

    test('reschedules all 4 WeTax cron jobs', () {
      const jobs = [
        'wetax-dispatcher-every-minute',
        'wetax-poller-every-2-minutes',
        'wetax-daily-close-00-hcmc',
        'wetax-commons-refresh-weekly',
      ];
      for (final job in jobs) {
        final schedulePattern = RegExp(
          "cron\\.schedule\\(\\s*'$job'",
          multiLine: true,
        );
        expect(
          schedulePattern.hasMatch(migrationContent),
          isTrue,
          reason: 'Must reschedule $job with vault-based secret',
        );
      }
    });

    test('includes verification queries', () {
      expect(
        migrationContent,
        contains('cron.job_run_details'),
        reason: 'Must include verification query for confirming success',
      );
    });

    test('edge functions already read from Deno.env', () {
      const edgeFunctions = [
        'supabase/functions/wetax-dispatcher/index.ts',
        'supabase/functions/wetax-poller/index.ts',
        'supabase/functions/wetax-daily-close/index.ts',
        'supabase/functions/generate-settlement/index.ts',
        'supabase/functions/generate_delivery_settlement/index.ts',
      ];
      for (final path in edgeFunctions) {
        final file = File(path);
        if (!file.existsSync()) continue;
        final content = file.readAsStringSync();
        expect(
          content,
          contains('Deno.env.get'),
          reason: '$path must read CRON_SECRET from env',
        );
      }
    });
  });
}
