import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/qc_service.dart';
import 'package:globos_pos_system/features/qc/qc_provider.dart';

class _Service extends QcService {
  final reads = <String, List<Completer<List<Map<String, dynamic>>>>>{};

  Future<List<Map<String, dynamic>>> read(String key) {
    final pending = Completer<List<Map<String, dynamic>>>();
    reads.putIfAbsent(key, () => []).add(pending);
    return pending.future;
  }

  @override
  Future<List<Map<String, dynamic>>> fetchChecks({
    required String storeId,
    required DateTime from,
    required DateTime to,
  }) => read(storeId);

  @override
  Future<List<Map<String, dynamic>>> fetchFollowups({
    required String storeId,
    String? statusFilter,
  }) => read(storeId);

  @override
  Future<List<Map<String, dynamic>>> fetchIssueQueue({
    required String storeId,
  }) => read(storeId);
}

void main() {
  test(
    'QC week never resurrects a previous store after a later read',
    () async {
      final service = _Service();
      final notifier = QcCheckNotifier(service: service);
      final a = notifier.loadWeek(
        storeId: 'a',
        weekStart: DateTime(2026, 11, 1),
      );
      final b = notifier.loadWeek(
        storeId: 'b',
        weekStart: DateTime(2026, 11, 1),
      );
      service.reads['b']!.single.complete([
        {'id': 'b'},
      ]);
      await b;
      service.reads['a']!.single.complete([
        {'id': 'a'},
      ]);
      await a;
      expect(notifier.state.checks.single['id'], 'b');
      notifier.dispose();
    },
  );

  test('date-range scope change clears old week data immediately', () async {
    final service = _Service();
    final notifier = QcCheckNotifier(service: service);
    final initial = notifier.loadWeek(
      storeId: 'a',
      weekStart: DateTime(2026, 11, 1),
    );
    service.reads['a']!.single.complete([
      {'id': 'a'},
    ]);
    await initial;
    final pending = notifier.loadDateRange(
      storeId: 'b',
      from: DateTime(2026, 11, 1),
      to: DateTime(2026, 11, 2),
    );
    expect(notifier.state.checks, isEmpty);
    service.reads['b']!.single.complete([
      {'id': 'b'},
    ]);
    await pending;
    expect(notifier.state.dateRangeChecks.single['id'], 'b');
    notifier.dispose();
  });

  test(
    'follow-up failure from an old filter does not overwrite current data',
    () async {
      final service = _Service();
      final notifier = QcFollowupNotifier(service: service);
      final old = notifier.load('a', statusFilter: 'open');
      final latest = notifier.load('a', statusFilter: 'closed');
      service.reads['a']![1].complete([
        {'id': 'closed'},
      ]);
      await latest;
      service.reads['a']![0].completeError(StateError('old failure'));
      await old;
      expect(notifier.state.followups.single['id'], 'closed');
      expect(notifier.state.error, isNull);
      notifier.dispose();
    },
  );

  test(
    'issue queue and inspection reads ignore completion after disposal',
    () async {
      final service = _Service();
      final queue = QcIssueQueueNotifier(service: service);
      final checks = QcCheckNotifier(service: service);
      final a = queue.load('a');
      final b = checks.loadWeek(storeId: 'b', weekStart: DateTime(2026, 11, 1));
      queue.dispose();
      checks.dispose();
      service.reads['a']!.single.complete([
        {'id': 'old'},
      ]);
      service.reads['b']!.single.completeError(StateError('old failure'));
      await Future.wait([a, b]);
    },
  );
}
