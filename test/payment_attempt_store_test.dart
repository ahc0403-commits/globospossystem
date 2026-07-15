import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/payment_attempt_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('attempt id survives provider and application recreation', () async {
    final preferences = await SharedPreferences.getInstance();
    var generated = 0;
    String nextId() => 'attempt-${++generated}';
    final now = DateTime.utc(2026, 7, 15, 1);
    final scope = PaymentAttemptScope(
      actorAuthId: 'actor-a',
      storeId: 'store-a',
      orderId: 'order-a',
      splitIndex: 0,
      method: 'CASH',
      amount: 125000,
    );

    final firstStore = PaymentAttemptStore(
      preferences: () async => preferences,
      now: () => now,
      idFactory: nextId,
    );
    final first = await firstStore.getOrCreate(scope);

    final recreatedStore = PaymentAttemptStore(
      preferences: () async => preferences,
      now: () => now.add(const Duration(minutes: 1)),
      idFactory: nextId,
    );
    final replay = await recreatedStore.getOrCreate(scope);

    expect(replay, first);
    expect(generated, 1);
  });

  test('materially changed split gets a different attempt id', () async {
    final preferences = await SharedPreferences.getInstance();
    var generated = 0;
    final store = PaymentAttemptStore(
      preferences: () async => preferences,
      idFactory: () => 'attempt-${++generated}',
    );
    const original = PaymentAttemptScope(
      actorAuthId: 'actor-a',
      storeId: 'store-a',
      orderId: 'order-a',
      splitIndex: 1,
      method: 'CASH',
      amount: 50000,
    );
    const changed = PaymentAttemptScope(
      actorAuthId: 'actor-a',
      storeId: 'store-a',
      orderId: 'order-a',
      splitIndex: 1,
      method: 'CASH',
      amount: 60000,
    );

    expect(await store.getOrCreate(original), isNotEmpty);
    expect(
      await store.getOrCreate(changed),
      isNot(await store.getOrCreate(original)),
    );
  });

  test(
    '10x concurrent requests converge on one persisted attempt id',
    () async {
      final preferences = await SharedPreferences.getInstance();
      var generated = 0;
      final store = PaymentAttemptStore(
        preferences: () async => preferences,
        idFactory: () => 'attempt-${++generated}',
      );
      const scope = PaymentAttemptScope(
        actorAuthId: 'actor-a',
        storeId: 'store-a',
        orderId: 'order-concurrent',
        splitIndex: 0,
        method: 'CASH',
        amount: 75000,
      );

      final ids = await Future.wait(
        List<Future<String>>.generate(100, (_) => store.getOrCreate(scope)),
      );
      expect(ids.toSet(), hasLength(1));
      expect(generated, 1);
    },
  );

  test(
    'confirmed success clears the id and abandoned metadata is bounded',
    () async {
      final preferences = await SharedPreferences.getInstance();
      var generated = 0;
      var now = DateTime.utc(2026, 7, 1);
      final store = PaymentAttemptStore(
        preferences: () async => preferences,
        now: () => now,
        idFactory: () => 'attempt-${++generated}',
        maxEntries: 20,
        maxAge: const Duration(days: 7),
      );
      const confirmed = PaymentAttemptScope(
        actorAuthId: 'actor-a',
        storeId: 'store-a',
        orderId: 'order-confirmed',
        splitIndex: 0,
        method: 'CARD',
        amount: 100000,
      );

      final first = await store.getOrCreate(confirmed);
      await store.clear(confirmed);
      final afterClear = await store.getOrCreate(confirmed);
      expect(afterClear, isNot(first));

      for (var index = 0; index < 200; index++) {
        await store.getOrCreate(
          PaymentAttemptScope(
            actorAuthId: 'actor-a',
            storeId: 'store-a',
            orderId: 'order-$index',
            splitIndex: index,
            method: 'CASH',
            amount: index + 1,
          ),
        );
      }
      expect(await store.debugEntryCount(), lessThanOrEqualTo(20));

      now = now.add(const Duration(days: 8));
      await store.cleanup();
      expect(await store.debugEntryCount(), 0);
    },
  );
}
