import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/live_refresh_service.dart';
import 'package:globos_pos_system/core/services/menu_service.dart';
import 'package:globos_pos_system/features/admin/providers/menu_provider.dart';

class _Service extends MenuService {
  int fullReads = 0, categoryReads = 0, quantityReads = 0, active = 0, peak = 0;
  final batches = <Set<String>>[];
  Completer<Map<String, int?>>? blocked;
  @override
  Future<List<Map<String, dynamic>>> fetchCategories(String storeId) async {
    categoryReads++;
    return [
      {'id': 'category'},
    ];
  }

  @override
  Future<List<Map<String, dynamic>>> fetchItems(String storeId) async {
    fullReads++;
    return [
      {'id': 'a', 'name': 'keep menu choices', 'discount_remaining': 5},
      {'id': 'b', 'discount_remaining': 4},
    ];
  }

  @override
  Future<Map<String, int?>> fetchDiscountQuantities(
    String storeId,
    Set<String> ids,
  ) async {
    quantityReads++;
    batches.add(Set.of(ids));
    active++;
    if (active > peak) peak = active;
    try {
      return await (blocked?.future ??
          Future.value({for (final id in ids) id: 2}));
    } finally {
      active--;
    }
  }
}

PosLiveEvent change(Set<String>? ids) => PosLiveEvent(
  domain: 'menu',
  sourceTable: 'menu_discount_quantities',
  eventType: 'UPDATE',
  restaurantId: 'store',
  affectedMenuItemIds: ids,
);

void main() {
  test(
    'one quota update preserves menu/choices and skips the full catalog',
    () async {
      final service = _Service();
      final notifier = MenuNotifier('store', service: service);
      await notifier.fetchAll();
      final full = service.fullReads, categories = service.categoryReads;
      await notifier.refreshFromEvent(change({'a'}));
      expect(service.fullReads, full);
      expect(service.categoryReads, categories);
      expect(service.batches.single, {'a'});
      expect(
        notifier.state.items.requireValue.first['name'],
        'keep menu choices',
      );
      expect(notifier.state.items.requireValue.first['discount_remaining'], 2);
      expect(notifier.state.items.requireValue.last['discount_remaining'], 4);
      notifier.dispose();
    },
  );

  test('quota bursts keep one active read and one merged follow-up', () async {
    final service = _Service();
    final notifier = MenuNotifier('store', service: service);
    await notifier.fetchAll();
    service.blocked = Completer();
    final first = notifier.refreshFromEvent(change({'a'}));
    final pending = List.generate(
      100,
      (_) => notifier.refreshFromEvent(change({'b'})),
    );
    service.blocked!.complete({'a': 1, 'b': 0});
    await Future.wait([first, ...pending]);
    expect(service.quantityReads, 2);
    expect(service.peak, 1);
    expect(service.batches.last, {'b'});
    notifier.dispose();
  });

  test('legacy signal without IDs recovers through the full catalog', () async {
    final service = _Service();
    final notifier = MenuNotifier('store', service: service);
    await notifier.fetchAll();
    final before = service.fullReads;
    await notifier.refreshFromEvent(change(null));
    expect(service.fullReads, before + 1);
    notifier.dispose();
  });

  test('merged quota and other-domain events retain bounded menu IDs', () {
    final merged = change({'a'}).merge(
      const PosLiveEvent(
        domain: 'orders',
        sourceTable: 'orders',
        eventType: 'UPDATE',
        restaurantId: 'store',
      ),
    );
    expect(merged.onlyMenuQuantityChanges, isTrue);
    expect(merged.affectedMenuItemIds, {'a'});
    final mixed = merged.merge(
      const PosLiveEvent(
        domain: 'menu',
        sourceTable: 'menu_items',
        eventType: 'UPDATE',
        restaurantId: 'store',
      ),
    );
    expect(mixed.onlyMenuQuantityChanges, isFalse);
    expect(mixed.affectedMenuItemIds, isNull);
    final overflow = change({
      for (var i = 0; i < 100; i++) '$i',
    }).merge(change({'extra'}));
    expect(overflow.affectedMenuItemIds, isNull);
  });
}
