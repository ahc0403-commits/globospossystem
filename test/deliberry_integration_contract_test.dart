import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  group('Deliberry integration contract', () {
    test('hardens Deliberry read views with invoker security', () {
      final migration = File(
        'supabase/migrations/299_deliberry_integration_security_closure.sql',
      );

      expect(migration.existsSync(), isTrue);

      final sql = migration.readAsStringSync();
      for (final viewName in [
        'v_external_store_sales',
        'v_external_store_overview',
        'v_daily_revenue_by_channel',
        'v_settlement_summary',
      ]) {
        expect(
          sql,
          contains(
            'ALTER VIEW public.$viewName SET (security_invoker = true);',
          ),
          reason: '$viewName must not bypass table RLS through view ownership.',
        );
      }
    });

    test('settlement summary exposes the active store_id contract', () {
      final sql = readRepoFile(
        'supabase/migrations/299_deliberry_integration_security_closure.sql',
      );
      final provider = readRepoFile(
        'lib/features/delivery/delivery_settlement_provider.dart',
      );
      final model = readRepoFile('lib/features/delivery/delivery_models.dart');

      expect(sql, contains('ds.restaurant_id AS store_id'));
      expect(provider, contains(".from('v_settlement_summary')"));
      expect(provider, contains(".eq('store_id', storeId)"));
      expect(model, contains("json['store_id'] ?? json['restaurant_id']"));
    });

    test('legacy generate-settlement remains idempotent for a period', () {
      final source = readRepoFile(
        'supabase/functions/generate-settlement/index.ts',
      );

      expect(source, contains('.from("delivery_settlements")'));
      expect(source, contains('.eq("source_system", "deliberry")'));
      expect(source, contains('.eq("period_label", periodLabel)'));
      expect(source, contains('SETTLEMENT_ALREADY_EXISTS'));
    });
  });
}
