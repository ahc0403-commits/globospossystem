import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const migrationPath =
      'supabase/migrations/20260811083000_photo_objet_late_slot_recovery.sql';

  test('late scheduler starts remain exact-slot recoveries', () {
    final migration = File(migrationPath).readAsStringSync().toLowerCase();

    expect(migration, contains('photo_objet_claim_daily_execution'));
    expect(migration, contains("p_slot_time_hcm <> time '22:00'"));
    expect(migration, contains('v_now < v_scheduled_at'));
    expect(migration, isNot(contains('deadline_exceeded')));
    expect(migration, isNot(contains('hard_deadline')));
    expect(migration, isNot(contains('report_ready_deadline_exceeded')));
    expect(migration, contains("run.run_source = 'scheduled'"));
    expect(migration, contains('run.interval_end_at = v_scheduled_at'));
    expect(migration, isNot(contains('run.finished_at <')));
    expect(migration, contains('v_valid_runs <> v_required_stores'));
    expect(migration, contains('photo_objet_daily_report_is_ready'));
  });

  test(
    'production gate and recovery workflow cover delayed and missed runs',
    () {
      expect(
        File(
          'scripts/preflight_photo_objet_late_slot_recovery.sql',
        ).existsSync(),
        isTrue,
      );
      expect(
        File('scripts/verify_photo_objet_late_slot_recovery.sql').existsSync(),
        isTrue,
      );

      final workflow = File(
        '.github/workflows/photo_objet_sales_collect_recovery.yml',
      ).readAsStringSync();
      final runner = File(
        '.github/workflows/photo_objet_sales_collect_runner.yml',
      ).readAsStringSync();

      expect(workflow, isNot(contains('schedule:')));
      expect(workflow, contains(r'if: ${{ false }}'));
      expect(workflow, contains('workflow_dispatch:'));
      expect(workflow, contains('slot_date_hcm:'));
      expect(workflow, contains('executor_role: backup'));
      expect(workflow, contains("test \"\${SOURCE_REF}\" = 'refs/heads/main'"));
      expect(runner, contains('PHOTO_OBJET_SLOT_DATE_HCM'));
    },
  );
}
