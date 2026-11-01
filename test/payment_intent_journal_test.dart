import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/payments/payment_intent_journal_native.dart';
import 'package:sqlite3/sqlite3.dart';

Map<String, dynamic> record(int n, {String? order}) => {
  'version': 1,
  'operation': 'operation-$n',
  'project': 'https://fixture.invalid',
  'actor': 'actor',
  'store': 'store',
  'order': order ?? 'order-$n',
  'amount': 10000,
  'method': 'CASH',
  'expectedCount': 0,
  'full': true,
  'createdAt': 1000 + n,
  'revision': 1,
  'phase': 'prepared',
};

void main() {
  late Directory directory;
  late NativePaymentIntentJournal journal;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('owned-payment-journal-');
    journal = NativePaymentIntentJournal(directory);
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test(
    '20 concurrent native callers preserve exactly one original intent',
    () async {
      final results = await Future.wait(
        List.generate(
          20,
          (n) => NativePaymentIntentJournal(
            directory,
          ).mutate('claim', {'record': record(n, order: 'same')}),
        ),
      );
      expect(results.map((r) => r!['operation']).toSet(), hasLength(1));
      final reopened = NativePaymentIntentJournal(directory);
      expect(
        await reopened.list('https://fixture.invalid', 'actor', 'store'),
        hasLength(1),
      );
      expect(
        await reopened.list(
          'https://fixture.invalid',
          'another-actor',
          'store',
        ),
        isEmpty,
      );
    },
  );
  test(
    'two independent isolate queues share one SQLite ownership transaction',
    () async {
      await journal.mutate('claim', {'record': record(0)});
      final root = directory.path;
      final results = await Future.wait(
        List.generate(
          2,
          (n) => Isolate.run(
            () => NativePaymentIntentJournal(
              Directory(root),
            ).mutate('claim', {'record': record(n + 1, order: 'shared')}),
          ),
        ),
      );
      expect(results.map((r) => r!['operation']).toSet(), hasLength(1));
      expect(
        await journal.list('https://fixture.invalid', 'actor', 'store'),
        hasLength(2),
      );
    },
  );
  test('parallel distinct orders do not overwrite each other', () async {
    await Future.wait(
      List.generate(
        12,
        (n) => NativePaymentIntentJournal(
          directory,
        ).mutate('claim', {'record': record(n)}),
      ),
    );
    expect(
      await journal.list('https://fixture.invalid', 'actor', 'store'),
      hasLength(12),
    );
  });
  test('CAS loser receives original winner without mutating it', () async {
    final original = (await journal.mutate('claim', {'record': record(1)}))!;
    final next = {
      ...original,
      'phase': 'sending',
      'revision': 2,
      'sender': 'first',
    };
    await journal.mutate('update', {'record': next, 'expectedRevision': 1});
    final stale = await journal.mutate('update', {
      'record': {...next, 'sender': 'loser'},
      'expectedRevision': 1,
    });
    expect(stale!['sender'], 'first');
    expect(stale['revision'], 2);
  });
  test(
    'identity changes, illegal transitions and unresolved retirement roll back',
    () async {
      final original = (await journal.mutate('claim', {'record': record(1)}))!;
      await expectLater(
        journal.mutate('update', {
          'record': {
            ...original,
            'amount': 1,
            'revision': 2,
            'phase': 'sending',
          },
          'expectedRevision': 1,
        }),
        throwsStateError,
      );
      await expectLater(
        journal.mutate('update', {
          'record': {...original, 'revision': 2, 'phase': 'confirmed'},
          'expectedRevision': 1,
        }),
        throwsStateError,
      );
      await expectLater(
        journal.mutate('retire', {'record': original, 'expectedRevision': 1}),
        throwsStateError,
      );
      expect(
        (await journal.list(
          'https://fixture.invalid',
          'actor',
          'store',
        )).single,
        original,
      );
    },
  );
  test(
    '100-record capacity rejects growth and permits resolution and retirement',
    () async {
      for (var n = 0; n < 100; n++) {
        await journal.mutate('claim', {'record': record(n)});
      }
      await expectLater(
        journal.mutate('claim', {'record': record(100)}),
        throwsStateError,
      );
      final original = record(0);
      final next = {...original, 'phase': 'rejected', 'revision': 2};
      await journal.mutate('update', {'record': next, 'expectedRevision': 1});
      await journal.mutate('retire', {'record': next, 'expectedRevision': 2});
      await journal.mutate('claim', {'record': record(100)});
      expect(
        await journal.list('https://fixture.invalid', 'actor', 'store'),
        hasLength(100),
      );
    },
  );
  test(
    'malformed on-disk ledger is an error rather than an empty success',
    () async {
      await journal.mutate('claim', {'record': record(1)});
      final db = sqlite3.open('${directory.path}/intents.sqlite3');
      db.execute('UPDATE journal SET payload=?', [
        jsonEncode([
          {'corrupt': true},
        ]),
      ]);
      db.dispose();
      await expectLater(
        journal.list('https://fixture.invalid', 'actor', 'store'),
        throwsFormatException,
      );
      await expectLater(
        journal.mutate('claim', {'record': record(2)}),
        throwsFormatException,
      );
    },
  );
  test('record-size limit is enforced before write', () async {
    await expectLater(
      journal.mutate('claim', {
        'record': {...record(1), 'extra': 'x' * 8192},
      }),
      throwsFormatException,
    );
    expect(
      await journal.list('https://fixture.invalid', 'actor', 'store'),
      isEmpty,
    );
  });
}
