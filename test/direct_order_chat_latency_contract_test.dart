import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'customer chat uses bounded fast polling without overlapping requests',
    () {
      final source = File(
        'lib/features/direct_order/direct_order_storefront_screen.dart',
      ).readAsStringSync();

      expect(source, contains('Timer.periodic(const Duration(seconds: 2)'));
      expect(source, contains('_refreshingStatus'));
      expect(source, contains('_statusMutationRevision'));
      expect(
        source,
        contains('item.id == sent.id'),
        reason: 'the sender should see a confirmed message immediately',
      );
    },
  );

  test('staff chat receives isolated payload-free realtime invalidations', () {
    final cashier = File(
      'lib/features/direct_order/direct_order_cashier_screen.dart',
    ).readAsStringSync();
    final migration = File(
      'supabase/migrations/'
      '20260824030000_direct_order_chat_live_refresh.sql',
    ).readAsStringSync();

    expect(cashier, contains("event.affects({'direct_order_chat'})"));
    expect(cashier, contains('posLiveEventsProvider(storeId)'));
    expect(cashier, contains('const Duration(seconds: 30)'));
    expect(cashier, contains("rows.first['id']?.toString()"));
    expect(migration, contains('AFTER INSERT ON public.direct_order_messages'));
    expect(
      migration,
      contains("public.emit_pos_live_event('direct_order_chat')"),
    );
    expect(migration, isNot(contains('GRANT SELECT')));
    expect(migration, isNot(contains('ALTER PUBLICATION')));
    expect(migration, contains('-- production-gate: self-verifying'));
  });
}
