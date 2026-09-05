import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/utils/coalesced_refresh.dart';
import 'package:globos_pos_system/core/services/live_refresh_service.dart';

void main() {
  test(
    'a burst during a slow read runs one follow-up with no overlap',
    () async {
      final queue = CoalescedRefresh();
      final blocked = Completer<void>();
      var calls = 0;
      var active = 0;
      var peak = 0;
      Future<void> read() async {
        calls++;
        active++;
        if (active > peak) peak = active;
        if (calls == 1) await blocked.future;
        active--;
      }

      final first = queue.run(read);
      final rest = List.generate(100, (_) => queue.run(read));
      blocked.complete();
      await Future.wait([first, ...rest]);
      expect(calls, 2);
      expect(peak, 1);
      queue.dispose();
    },
  );
  test('failure does not abandon the pending refresh', () async {
    final queue = CoalescedRefresh();
    final blocked = Completer<void>();
    var followup = false;
    final first = queue.run(() async {
      await blocked.future;
      throw StateError('fixture');
    });
    queue.run(() async {
      followup = true;
    });
    final observed = expectLater(first, throwsStateError);
    blocked.complete();
    await observed;
    expect(followup, isTrue);
    await queue.run(() async {});
    queue.dispose();
  });
  test('dispose drops pending work', () async {
    final queue = CoalescedRefresh();
    final blocked = Completer<void>();
    var calls = 0;
    final first = queue.run(() async {
      calls++;
      await blocked.future;
    });
    queue.run(() async {
      calls++;
    });
    queue.dispose();
    blocked.complete();
    await first;
    await queue.run(() async {
      calls++;
    });
    expect(calls, 1);
  });
  test('merging stores never incorrectly retains only the last store', () {
    const a = PosLiveEvent(
      domain: 'orders',
      sourceTable: 'orders',
      eventType: 'UPDATE',
      restaurantId: 'a',
    );
    const b = PosLiveEvent(
      domain: 'payments',
      sourceTable: 'payments',
      eventType: 'INSERT',
      restaurantId: 'b',
    );
    expect(a.merge(b).restaurantId, isNull);
    expect(a.merge(b).domain, '*');
    expect(a.merge(b).affects({'settings'}), isFalse);
    expect(a.merge(a).restaurantId, 'a');
    expect(a.merge(const PosLiveEvent.fallback()).isFallback, isTrue);
  });

  test('nested merges retain original change tuples in either order', () {
    const insert = PosLiveEvent(
      domain: 'direct_orders',
      sourceTable: 'direct_order_requests',
      eventType: 'INSERT',
    );
    const update = PosLiveEvent(
      domain: 'orders',
      sourceTable: 'orders',
      eventType: 'UPDATE',
    );
    for (final merged in [
      insert.merge(update).merge(insert),
      update.merge(insert.merge(update)),
      const PosLiveEvent.fallback().merge(insert).merge(update),
    ]) {
      expect(
        merged.includesChange(
          domain: 'direct_orders',
          sourceTable: 'direct_order_requests',
          eventType: 'INSERT',
        ),
        isTrue,
      );
      expect(
        merged.includesChange(
          domain: 'orders',
          sourceTable: 'orders',
          eventType: 'UPDATE',
        ),
        isTrue,
      );
      expect(
        merged.includesChange(
          domain: 'orders',
          sourceTable: 'orders',
          eventType: 'INSERT',
        ),
        isFalse,
        reason: 'an INSERT on another table must not invent one here',
      );
    }
    expect(
      const PosLiveEvent.fallback().includesChange(
        domain: 'direct_orders',
        sourceTable: 'direct_order_requests',
        eventType: 'INSERT',
      ),
      isFalse,
    );
  });
}
