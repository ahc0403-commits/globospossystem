import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import 'payment_intent_journal.dart';

Future<PaymentIntentJournal> openPaymentIntentJournal() async =>
    NativePaymentIntentJournal(
      Directory(
        p.join(
          (await getApplicationSupportDirectory()).path,
          'payment_intents_v1',
        ),
      ),
    );

/// Dedicated financial journal, never the read-only menu cache. SQLite's
/// transaction protects across processes AND isolates (POSIX file locks alone
/// are process-scoped). Bounded synchronous DB work runs outside the UI isolate.
class NativePaymentIntentJournal implements PaymentIntentJournal {
  NativePaymentIntentJournal(this.directory);
  final Directory directory;
  static final _tails = <String, Future<void>>{};
  static final _pending = <String, int>{};

  static Future<T> _serialize<T>(
    String root,
    Future<T> Function() action,
  ) async {
    final count = _pending[root] ?? 0;
    if (count >= 100) throw StateError('PAYMENT_JOURNAL_BUSY');
    _pending[root] = count + 1;
    final previous = _tails[root] ?? Future<void>.value();
    final done = Completer<void>();
    final tail = done.future;
    _tails[root] = tail;
    try {
      await previous;
      return await action();
    } finally {
      done.complete();
      final remaining = (_pending[root] ?? 1) - 1;
      if (remaining == 0) {
        _pending.remove(root);
      } else {
        _pending[root] = remaining;
      }
      if (identical(_tails[root], tail)) _tails.remove(root);
    }
  }

  Future<T> _transaction<T>(
    T Function(List<Map<String, dynamic>>) action, {
    required bool write,
  }) {
    final root = directory.absolute.path;
    return _serialize(
      root,
      () => Isolate.run(() {
        Directory(root).createSync(recursive: true);
        final db = sqlite3.open(p.join(root, 'intents.sqlite3'));
        try {
          db.execute('PRAGMA busy_timeout=2000');
          db.execute('PRAGMA synchronous=FULL');
          db.execute('PRAGMA max_page_count=256');
          db.execute(
            'CREATE TABLE IF NOT EXISTS journal (id INTEGER PRIMARY KEY CHECK(id=1), payload TEXT NOT NULL CHECK(length(CAST(payload AS BLOB))<=262144))',
          );
          db.execute(write ? 'BEGIN IMMEDIATE' : 'BEGIN');
          final data = db.select('SELECT payload FROM journal WHERE id=1');
          final raw = data.isEmpty
              ? <dynamic>[]
              : jsonDecode(data.single['payload'] as String);
          if (raw is! List || raw.length > 100) {
            throw const FormatException('PAYMENT_JOURNAL_INVALID');
          }
          final rows = raw
              .map((r) => Map<String, dynamic>.from(r as Map))
              .toList();
          for (final row in rows) {
            validatePaymentIntent(row);
          }
          if (rows.map(paymentIntentSlot).toSet().length != rows.length ||
              rows.map((r) => r['operation']).toSet().length != rows.length) {
            throw const FormatException('PAYMENT_JOURNAL_DUPLICATE');
          }
          final result = action(rows);
          if (write) {
            db.execute(
              'INSERT INTO journal(id,payload) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload',
              [jsonEncode(rows)],
            );
          }
          db.execute('COMMIT');
          return result;
        } finally {
          db.dispose();
        }
      }),
    );
  }

  @override
  Future<Map<String, dynamic>?> mutate(
    String action,
    Map<String, dynamic> input,
  ) {
    final frozen = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(input)) as Map,
    );
    return _transaction(
      (rows) => mutatePaymentIntents(rows, action, frozen),
      write: true,
    );
  }

  @override
  Future<List<Map<String, dynamic>>> list(
    String project,
    String actor,
    String store,
  ) => _transaction(
    (rows) => rows
        .where(
          (r) =>
              r['project'] == project &&
              r['actor'] == actor &&
              r['store'] == store,
        )
        .toList(),
    write: false,
  );
}
