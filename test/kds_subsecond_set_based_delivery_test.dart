import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const migrationPath =
      'supabase/migrations/20260920100000_kds_subsecond_set_based_delivery.sql';
  final migration = File(migrationPath).readAsStringSync();

  String functionBody(String signature, String nextMarker) {
    final start = migration.indexOf(signature);
    final end = migration.indexOf(nextMarker, start + signature.length);
    expect(start, greaterThanOrEqualTo(0), reason: signature);
    expect(end, greaterThan(start), reason: nextMarker);
    return migration.substring(start, end).toLowerCase();
  }

  test('hot KDS batches use one set-based mutation helper', () {
    final helper = functionBody(
      'CREATE OR REPLACE FUNCTION public.kds_apply_station_progress_batch_v1',
      'REVOKE ALL ON FUNCTION public.kds_apply_station_progress_batch_v1',
    );
    expect(helper, isNot(contains(' loop')));
    expect(helper, isNot(contains('foreach')));
    expect(helper, isNot(contains('kds_record_station_progress_v3(')));
    expect(helper, isNot(contains('kds_record_progress_v2(')));
    expect(helper, contains('jsonb_to_recordset'));
    expect(helper, contains('update public.emergency_fulfillment_items'));
    expect(helper, contains('update public.emergency_combo_component_items'));
    expect(helper, contains('insert into public.emergency_fulfillment_events'));
    expect(helper, contains('on conflict (event_id, device_id) do nothing'));
  });

  test('all public batch RPCs call the helper once without SQL loops', () {
    final bodies = [
      functionBody(
        'CREATE OR REPLACE FUNCTION public.kds_complete_kitchen_batch_v1',
        'CREATE OR REPLACE FUNCTION public.kds_dispatch_tray_floor_batch_v1',
      ),
      functionBody(
        'CREATE OR REPLACE FUNCTION public.kds_dispatch_tray_floor_batch_v1',
        'CREATE OR REPLACE FUNCTION public.kds_complete_customer_delivery_batch_v1',
      ),
      functionBody(
        'CREATE OR REPLACE FUNCTION public.kds_complete_customer_delivery_batch_v1',
        'REVOKE ALL ON FUNCTION public.kds_complete_kitchen_batch_v1',
      ),
    ];
    for (final body in bodies) {
      expect(body, isNot(contains(' loop')));
      expect(body, isNot(contains('foreach')));
      expect(body, isNot(contains('kds_record_station_progress_v3(')));
      expect(body, isNot(contains('kds_record_progress_v2(')));
      expect(
        RegExp('kds_apply_station_progress_batch_v1\\(').allMatches(body),
        hasLength(1),
      );
    }
  });

  test('legacy realtime tables are both included in the publication', () {
    expect(migration, contains("tablename = 'emergency_fulfillment_actions'"));
    expect(migration, contains("tablename = 'emergency_fulfillment_events'"));
    expect(
      migration,
      contains('ADD TABLE public.emergency_fulfillment_actions'),
    );
    expect(
      migration,
      contains('ADD TABLE public.emergency_fulfillment_events'),
    );
  });

  test(
    'release has preflight, verification, and reversible SQL definitions',
    () {
    for (final path in [
      'scripts/preflight_kds_subsecond_set_based_delivery.sql',
      'scripts/verify_kds_subsecond_set_based_delivery.sql',
      'scripts/rollback_kds_subsecond_set_based_delivery.sql',
      'supabase/tests/kds_subsecond_set_based_delivery_test.sql',
    ]) {
        expect(File(path).existsSync(), isTrue, reason: path);
      }
      expect(migration, contains('-- production-gate: self-verifying'));
      expect(migration, contains('loop_backup_v1'));
      expect(
        migration.toLowerCase(),
        isNot(contains('insert into public.payments')),
      );
    },
  );
}
