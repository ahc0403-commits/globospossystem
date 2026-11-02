import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/orders/order_intent_journal_native.dart';

Map<String, dynamic> record(int n, {String target = 'table'}) => {
  'version': 1,
  'operation': 'op-$n',
  'project': 'fixture',
  'actor': 'actor',
  'store': 'store',
  'kind': 'create',
  'target': target,
  'payload': jsonEncode({
    'p_store_id': 'store',
    'p_table_id': target,
    'p_items': [
      {'menu_item_id': 'menu', 'quantity': 1},
    ],
  }),
  'createdAt': n + 1,
  'revision': 1,
  'phase': 'prepared',
};

void main() {
  late Directory dir;
  late NativeOrderIntentJournal journal;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('owned-order-journal-');
    journal = NativeOrderIntentJournal(dir);
  });
  tearDown(() async {
    await dir.delete(recursive: true);
  });

  test(
    '20 independent native callers retain exactly one original intent',
    () async {
      final result = await Future.wait(
        List.generate(
          20,
          (n) => NativeOrderIntentJournal(
            dir,
          ).mutate('claim', {'record': record(n)}),
        ),
      );
      expect(result.map((r) => r!['operation']).toSet(), hasLength(1));
      expect(await journal.list('fixture', 'actor', 'store'), hasLength(1));
      expect(await journal.list('fixture', 'another', 'store'), isEmpty);
    },
  );
  test('independent isolates share the SQLite transaction', () async {
    final root = dir.path;
    final result = await Future.wait(
      List.generate(
        2,
        (n) => Isolate.run(
          () => NativeOrderIntentJournal(
            Directory(root),
          ).mutate('claim', {'record': record(n)}),
        ),
      ),
    );
    expect(result.map((r) => r!['operation']).toSet(), hasLength(1));
  });
  test(
    'reopen preserves unknown and original payload; retirement is forbidden',
    () async {
      final original = (await journal.mutate('claim', {'record': record(1)}))!;
      final unknown = {...original, 'revision': 2, 'phase': 'unknown'};
      await journal.mutate('update', {
        'record': unknown,
        'expectedRevision': 1,
      });
      final reopened = NativeOrderIntentJournal(dir);
      expect(await reopened.mutate('claim', {'record': record(2)}), unknown);
      await expectLater(
        reopened.mutate('retire', {'record': unknown, 'expectedRevision': 2}),
        throwsStateError,
      );
      final changed = {
        ...unknown,
        'revision': 3,
        'phase': 'confirmed',
        'payload': jsonEncode({
          'p_store_id': 'store',
          'p_table_id': 'table',
          'p_items': [
            {'menu_item_id': 'menu', 'quantity': 99},
          ],
        }),
      };
      await expectLater(
        reopened.mutate('update', {'record': changed, 'expectedRevision': 2}),
        throwsStateError,
      );
      expect(
        (await reopened.list('fixture', 'actor', 'store')).single,
        unknown,
      );
    },
  );
  test(
    'batch settlement cannot remove another actor or discard a rejected request',
    () async {
      for (var n = 0; n < 3; n++) {
        await journal.mutate('claim', {'record': record(n, target: 't$n')});
      }
      await journal.mutate('settle', {
        'project': 'fixture',
        'actor': 'another',
        'store': 'store',
        'operations': ['op-0'],
      });
      expect(await journal.list('fixture', 'actor', 'store'), hasLength(3));
      await journal.mutate('settle', {
        'project': 'fixture',
        'actor': 'actor',
        'store': 'store',
        'operations': ['op-0'],
        'rejected': ['op-1'],
      });
      final rows = await journal.list('fixture', 'actor', 'store');
      expect(rows, hasLength(2));
      expect(
        rows.firstWhere((r) => r['operation'] == 'op-1')['phase'],
        'rejected',
      );
    },
  );
  test('oversize requests fail without modifying existing intents', () async {
    await journal.mutate('claim', {'record': record(1)});
    final r = record(2, target: 'other');
    final payload = jsonDecode(r['payload'] as String) as Map;
    payload['notes'] = 'x' * (256 * 1024);
    r['payload'] = jsonEncode(payload);
    await expectLater(
      journal.mutate('claim', {'record': r}),
      throwsFormatException,
    );
    expect(await journal.list('fixture', 'actor', 'store'), hasLength(1));
  });
}
