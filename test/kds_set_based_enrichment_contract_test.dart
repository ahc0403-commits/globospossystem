import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const migrationPath =
      'supabase/migrations/20260919160000_kds_set_based_enrichment.sql';
  final migration = File(migrationPath).readAsStringSync();

  test('KDS enrichment migration version is unique', () {
    final version = File(migrationPath).uri.pathSegments.last.split('_').first;
    final matchingMigrations = Directory('supabase/migrations')
        .listSync()
        .whereType<File>()
        .where((file) => file.uri.pathSegments.last.startsWith('${version}_'))
        .toList();

    expect(matchingMigrations, hasLength(1));
  });

  test('KDS enrichment is set-based, scoped, and reversible', () {
    final functionBody = migration
        .split('AS \$function\$')
        .last
        .split('\$function\$;')
        .first;
    expect(migration, contains('-- production-gate: self-verifying'));
    expect(functionBody, contains('WITH ORDINALITY'));
    expect(functionBody, contains('requested_source_lines'));
    expect(functionBody, contains('requested_queues'));
    expect(functionBody, contains('pending_source_ready'));
    expect(functionBody, contains('pending_queue_ready'));
    expect(functionBody, contains('jsonb_agg('));
    expect(functionBody, isNot(contains('FOR v_order IN')));
    expect(functionBody, isNot(contains('FOR v_item IN')));
    expect(
      migration,
      contains('emergency_enrich_start_ready_orders_pre_500_scale'),
    );
    expect(migration, contains('FROM PUBLIC, anon, authenticated'));

    for (final path in [
      'scripts/preflight_kds_set_based_enrichment.sql',
      'scripts/verify_kds_set_based_enrichment.sql',
      'scripts/rollback_kds_set_based_enrichment.sql',
      'test/fixtures/kds_set_based_enrichment_setup.sql',
      'test/fixtures/kds_set_based_enrichment_assert.sql',
    ]) {
      expect(File(path).existsSync(), isTrue, reason: path);
    }
  });

  test('set enrichment preserves every workflow data source', () {
    for (final source in [
      'emergency_order_queue',
      'emergency_fulfillment_items',
      'emergency_combo_component_items',
      'emergency_floor_direct_items',
      'emergency_floor_ready_lots',
      'kitchen_started_quantity',
      'excused_quantity',
      'required_quantity',
      'oldest_ready_sequence',
      'workflow_version',
    ]) {
      expect(migration, contains(source), reason: source);
    }
  });
}
