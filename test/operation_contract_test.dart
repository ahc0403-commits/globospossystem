import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/utils/operation_contract.dart';
import 'package:globos_pos_system/core/utils/read_epoch.dart';

OperationScope scope({String actor = 'actor', String revision = '1'}) =>
    OperationScope(
      actorId: actor,
      storeId: 'store',
      legalEntityId: 'legal',
      role: 'cashier',
      authorizationRevision: revision,
    );

void main() {
  test('view checkpoints do not start reads and never survive A to B to A', () {
    final reads = ReadEpoch();
    expect(reads.currentToken, isNull);
    final original = reads.begin('a');
    final checkpoint = reads.currentToken!;
    expect(reads.accepts(original), isTrue);
    expect(reads.accepts(checkpoint), isTrue);
    reads.begin('b');
    reads.begin('a');
    expect(reads.accepts(checkpoint), isFalse);
    final current = reads.currentToken!;
    reads.dispose();
    expect(reads.accepts(current), isFalse);
    expect(reads.currentToken, isNull);
  });

  test('actor and permission revision are part of scope/cache identity', () {
    expect(scope(), scope());
    expect(scope(), isNot(scope(actor: 'another')));
    expect(scope(), isNot(scope(revision: '2')));
    expect({scope(), scope(), scope(revision: '2')}, hasLength(2));
  });

  test('confirmed write remains confirmed when its view scope changes', () {
    final original = scope();
    final result = CommandOutcome.confirmed(
      operationId: 'operation',
      scope: original,
      value: 'payment',
      resultId: 'payment',
    );
    final reads = ReadEpoch();
    final old = reads.begin(original);
    reads.begin(scope(actor: 'another'));
    expect(reads.accepts(old), isFalse);
    expect(result.status, CommandStatus.confirmed);
    expect(result.scope, original);
  });

  test(
    'queued needs a durable entry and unknown retains recovery identity',
    () {
      final queued = CommandOutcome<void>.queued(
        operationId: 'event',
        scope: scope(),
        durableEntryId: 'outbox-event',
        recoveryKey: 'event',
      );
      final unknown = CommandOutcome<void>.unknown(
        operationId: 'event',
        scope: scope(),
        recoveryKey: 'event',
      );
      expect(queued.evidenceId, 'outbox-event');
      expect(unknown.requiresReconciliation, isTrue);
      expect(unknown.evidenceId, isNull);
      expect(unknown.operationId, queued.operationId);
    },
  );

  test('latest query wins including A to B to A and disposal', () {
    final reads = ReadEpoch();
    final a = reads.begin(('store-a', 'week-1'));
    final b = reads.begin(('store-b', 'week-1'));
    final newest = reads.begin(('store-a', 'week-1'));
    expect(reads.accepts(a), isFalse);
    expect(reads.accepts(b), isFalse);
    expect(reads.accepts(newest), isTrue);
    reads.dispose();
    expect(reads.accepts(newest), isFalse);
    expect(() => reads.begin('later'), throwsStateError);
  });

  test('a token cannot be accepted by another lifetime', () {
    final first = ReadEpoch(), second = ReadEpoch();
    final token = first.begin('same');
    second.begin('same');
    expect(second.accepts(token), isFalse);
  });

  test('fresh empty data differs from failed and stale data', () {
    final empty = ScopedReadValue<List<int>>(
      freshness: ReadFreshness.fresh,
      scope: scope(),
      queryKey: 'query',
      value: const [],
    );
    final failed = ScopedReadValue<List<int>>(
      freshness: ReadFreshness.failed,
      scope: scope(),
      queryKey: 'query',
      error: StateError('denied'),
    );
    expect(empty.value, isEmpty);
    expect(empty.freshness, ReadFreshness.fresh);
    expect(failed.value, isNull);
    expect(failed.error, isNotNull);
  });
}
