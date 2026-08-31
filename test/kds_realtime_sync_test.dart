import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/emergency_fulfillment/kds_realtime_sync.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  group('KDS v2 wire contract', () {
    test('unknown modes remain on the legacy path', () {
      expect(KdsSyncMode.fromValue('shadow'), KdsSyncMode.shadow);
      expect(KdsSyncMode.fromValue('active'), KdsSyncMode.active);
      expect(KdsSyncMode.fromValue('unexpected'), KdsSyncMode.legacy);
      expect(KdsSyncMode.fromValue(null), KdsSyncMode.legacy);
    });

    test('subscription identity excludes only the high-watermark revision', () {
      const original = KdsSyncConfig(
        mode: KdsSyncMode.active,
        revision: 4,
        assigned: true,
        restaurantId: 'store-1',
        sessionId: 'session-1',
        stationType: 'floor',
        floorLabel: '1F',
      );
      const newer = KdsSyncConfig(
        mode: KdsSyncMode.active,
        revision: 99,
        assigned: true,
        restaurantId: 'store-1',
        sessionId: 'session-1',
        stationType: 'floor',
        floorLabel: '1F',
      );
      const movedFloor = KdsSyncConfig(
        mode: KdsSyncMode.active,
        revision: 99,
        assigned: true,
        restaurantId: 'store-1',
        sessionId: 'session-1',
        stationType: 'floor',
        floorLabel: '2F',
      );

      expect(original.hasSameSubscriptionAs(newer), isTrue);
      expect(original.hasSameSubscriptionAs(movedFloor), isFalse);
    });

    test('valid envelope and sparse delta metadata are parsed exactly', () {
      final delta = KdsDeltaBatch.fromJson({
        'bootstrap_required': false,
        'scanned_through_revision': 12,
        'current_revision': 15,
        'has_more': true,
        'changes': [
          {
            'schema_version': 1,
            'restaurant_id': 'store-1',
            'session_id': 'session-1',
            'revision': 11,
            'event_id': 'event-1',
            'event_type': 'ticket_changed',
            'target_stations': ['kitchen', 'tray'],
            'queue_id': 'queue-1',
            'payload': {'kind': 'ticket_invalidated', 'queue_id': 'queue-1'},
            'occurred_at': '2026-08-31T01:02:03Z',
          },
        ],
      });

      expect(delta.scannedThroughRevision, 12);
      expect(delta.currentRevision, 15);
      expect(delta.hasMore, isTrue);
      expect(delta.changes.single.revision, 11);
      expect(delta.changes.single.targetStations, ['kitchen', 'tray']);
      expect(delta.changes.single.kind, 'ticket_invalidated');
      expect(
        delta.changes.single.occurredAt,
        DateTime.utc(2026, 8, 31, 1, 2, 3),
      );
    });

    test('invalid schema or revision is rejected before state mutation', () {
      Map<String, dynamic> envelope({
        required int schema,
        required int revision,
      }) => {
        'schema_version': schema,
        'restaurant_id': 'store-1',
        'revision': revision,
        'event_id': 'event-1',
      };

      expect(
        () => KdsChangeEnvelope.fromJson(envelope(schema: 2, revision: 1)),
        throwsFormatException,
      );
      expect(
        () => KdsChangeEnvelope.fromJson(envelope(schema: 1, revision: 0)),
        throwsFormatException,
      );
    });
  });

  group('KDS durable catch-up', () {
    test(
      'applies pages in revision order and persists scanned cursor',
      () async {
        final gateway = _FakeGateway([
          _batch(scanned: 6, current: 8, hasMore: true, revisions: [5]),
          _batch(scanned: 8, current: 8, hasMore: false, revisions: [7, 8]),
        ]);
        final revisions = _MemoryRevisionStore();
        final applied = <int>[];
        final errors = <Object>[];
        final sync = _sync(
          gateway: gateway,
          revisionStore: revisions,
          onChange: (change) async => applied.add(change.revision),
          onError: (error, _) => errors.add(error),
        )..seedCursorForTesting(4);

        await sync.catchUp();

        expect(gateway.requestedAfter, [4, 6]);
        expect(applied, [5, 7, 8]);
        expect(sync.cursor, 8);
        expect(revisions.writes, [6, 8]);
        expect(errors, isEmpty);
      },
    );

    test('retention gap requests bootstrap without advancing cursor', () async {
      final gateway = _FakeGateway([
        const KdsDeltaBatch(
          bootstrapRequired: true,
          scannedThroughRevision: 3,
          currentRevision: 30,
          hasMore: false,
          changes: [],
        ),
      ]);
      var bootstrapCount = 0;
      final sync = _sync(
        gateway: gateway,
        onBootstrapRequired: () async => bootstrapCount += 1,
      )..seedCursorForTesting(3);

      await sync.catchUp();

      expect(bootstrapCount, 1);
      expect(sync.cursor, 3);
    });

    test('cursor regression is rejected and reported', () async {
      final gateway = _FakeGateway([
        _batch(scanned: 8, current: 10, hasMore: false, revisions: const []),
      ]);
      final errors = <Object>[];
      final sync = _sync(
        gateway: gateway,
        onError: (error, _) => errors.add(error),
      )..seedCursorForTesting(9);

      await sync.catchUp();

      expect(sync.cursor, 9);
      expect(errors.single, isA<StateError>());
    });
  });
}

KdsRealtimeSync _sync({
  required KdsSyncGateway gateway,
  KdsRevisionStore? revisionStore,
  KdsChangeHandler? onChange,
  KdsAsyncCallback? onBootstrapRequired,
  KdsSyncErrorHandler? onError,
}) => KdsRealtimeSync(
  client: SupabaseClient('http://localhost:54321', 'test-anon-key'),
  gateway: gateway,
  config: const KdsSyncConfig(
    mode: KdsSyncMode.active,
    revision: 0,
    assigned: true,
    restaurantId: 'store-1',
    sessionId: 'session-1',
    stationType: 'kitchen',
  ),
  revisionStore: revisionStore ?? _MemoryRevisionStore(),
  onChange: onChange ?? (_) async {},
  onBootstrapRequired: onBootstrapRequired ?? () async {},
  onConnected: () async {},
  onError: onError ?? (_, _) {},
);

KdsDeltaBatch _batch({
  required int scanned,
  required int current,
  required bool hasMore,
  required List<int> revisions,
}) => KdsDeltaBatch(
  bootstrapRequired: false,
  scannedThroughRevision: scanned,
  currentRevision: current,
  hasMore: hasMore,
  changes: revisions
      .map(
        (revision) => KdsChangeEnvelope(
          schemaVersion: 1,
          restaurantId: 'store-1',
          revision: revision,
          eventId: 'event-$revision',
          eventType: 'ticket_changed',
          targetStations: const ['kitchen'],
          payload: const {'kind': 'ticket_invalidated'},
          occurredAt: DateTime.utc(2026, 8, 31),
        ),
      )
      .toList(growable: false),
);

class _FakeGateway implements KdsSyncGateway {
  _FakeGateway(this.batches);

  final List<KdsDeltaBatch> batches;
  final List<int> requestedAfter = [];
  int _index = 0;

  @override
  Future<KdsDeltaBatch> loadChanges(
    int afterRevision, {
    int limit = 100,
  }) async {
    requestedAfter.add(afterRevision);
    return batches[_index++];
  }

  @override
  Future<KdsBootstrap> loadBootstrap() => throw UnimplementedError();

  @override
  Future<KdsSyncConfig> loadConfig() => throw UnimplementedError();

  @override
  Future<int> loadHighWatermark() => throw UnimplementedError();

  @override
  Future<KdsTicketResult> loadTicket(String queueId) =>
      throw UnimplementedError();
}

class _MemoryRevisionStore implements KdsRevisionStore {
  final List<int> writes = [];

  @override
  Future<int?> read(String key) async => null;

  @override
  Future<void> write(String key, int revision) async => writes.add(revision);
}
