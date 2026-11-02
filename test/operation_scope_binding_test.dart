import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/auth/operation_scope_provider.dart';
import 'package:globos_pos_system/core/services/qc_service.dart';
import 'package:globos_pos_system/features/auth/auth_state.dart';
import 'package:globos_pos_system/features/auth/operation_scope_binding.dart';
import 'package:globos_pos_system/features/qc/qc_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

PosAuthState _auth({
  String actor = 'actor-a',
  String store = 'store-a',
  String role = 'cashier',
  List<String> permissions = const ['orders', 'reports'],
  List<AccessibleStore>? stores,
  String email = 'first@example.invalid',
  Map<String, dynamic> metadata = const {},
}) => PosAuthState(
  user: User(
    id: actor,
    appMetadata: const {},
    userMetadata: metadata,
    aud: 'authenticated',
    createdAt: '2026-11-01T00:00:00Z',
    email: email,
  ),
  role: role,
  storeId: store,
  primaryStoreId: 'store-a',
  extraPermissions: permissions,
  accessibleStores:
      stores ??
      const [
        AccessibleStore(
          id: 'store-a',
          name: 'Store A',
          brandId: 'brand-a',
          legalEntityId: 'legal-a',
        ),
        AccessibleStore(
          id: 'store-b',
          name: 'Store B',
          brandId: 'brand-b',
          legalEntityId: 'legal-b',
        ),
      ],
);

class _Qc extends QcService {
  final reads = <Completer<List<Map<String, dynamic>>>>[];
  final writes = <Completer<void>>[];

  @override
  Future<List<Map<String, dynamic>>> fetchFollowups({
    required String storeId,
    String? statusFilter,
  }) {
    final pending = Completer<List<Map<String, dynamic>>>();
    reads.add(pending);
    return pending.future;
  }

  @override
  Future<List<Map<String, dynamic>>> fetchIssueQueue({
    required String storeId,
  }) => fetchFollowups(storeId: storeId);

  @override
  Future<void> createFollowup({
    required String storeId,
    required String sourceCheckId,
    String? assignedToName,
  }) {
    final pending = Completer<void>();
    writes.add(pending);
    return pending.future;
  }
}

void main() {
  final auth = StateProvider<PosAuthState>((ref) => _auth());
  late ProviderContainer container;
  late _Qc service;

  setUp(() {
    service = _Qc();
    container = ProviderContainer(
      overrides: [
        operationScopeProvider.overrideWith(
          (ref) => bindOperationScope(ref, auth),
        ),
        qcServiceProvider.overrideWithValue(service),
      ],
    );
    container.read(operationScopeProvider);
  });
  tearDown(() => container.dispose());

  test('trusted store/legal/actor/role/access changes define the scope', () {
    final first = operationScopeFromAuth(_auth())!;
    expect(first.legalEntityId, 'legal-a');
    for (final next in [
      _auth(actor: 'actor-b'),
      _auth(store: 'store-b'),
      _auth(role: 'store_manager'),
      _auth(permissions: ['orders']),
      _auth(
        stores: const [
          AccessibleStore(
            id: 'store-a',
            name: 'Store A',
            legalEntityId: 'different-legal',
          ),
        ],
      ),
    ]) {
      expect(operationScopeFromAuth(next), isNot(first));
    }
  });

  test('token refresh, names, metadata and set order do not refresh data', () {
    final before = container.read(operationScopeProvider);
    final next =
        _auth(
          email: 'renamed@example.invalid',
          metadata: {'role': 'super_admin', 'store_id': 'injected'},
          permissions: ['reports', 'orders', 'orders'],
          stores: const [
            AccessibleStore(
              id: 'store-b',
              name: 'Renamed B',
              brandId: 'brand-b',
              legalEntityId: 'legal-b',
            ),
            AccessibleStore(
              id: 'store-a',
              name: 'Renamed A',
              brandId: 'brand-a',
              legalEntityId: 'legal-a',
            ),
          ],
        ).copyWith(
          isLoading: true,
          isRecoveringSession: true,
          errorMessage: 'retry',
        );
    container.read(auth.notifier).state = next;
    expect(container.read(operationScopeProvider), same(before));
    expect(before.scope!.role, 'cashier');
  });

  test(
    'A to B to A advances lifetime without an intermediate consumer read',
    () {
      final first = container.read(operationScopeProvider);
      container.read(auth.notifier).state = _auth(store: 'store-b');
      container.read(auth.notifier).state = _auth();
      final last = container.read(operationScopeProvider);
      expect(last.scope, first.scope);
      expect(last.generation, first.generation + 2);
    },
  );

  test(
    '100 profile refreshes share one read and 100 scope switches retain one lifetime',
    () async {
      var calls = 0;
      var live = 0;
      var disposed = 0;
      final data = FutureProvider<int>((ref) async {
        watchOperationScope(ref);
        live++;
        ref.onDispose(() {
          live--;
          disposed++;
        });
        return ++calls;
      });
      final sub = container.listen(data, (_, __) {});
      addTearDown(sub.close);
      expect(await container.read(data.future), 1);
      for (var i = 0; i < 100; i++) {
        container.read(auth.notifier).state = _auth(
          email: 'renamed-$i@example.invalid',
        ).copyWith(isLoading: i.isEven);
        expect(await container.read(data.future), 1);
      }
      expect(calls, 1);
      for (var i = 0; i < 100; i++) {
        container.read(auth.notifier).state = _auth(
          store: i.isEven ? 'store-b' : 'store-a',
        );
        expect(await container.read(data.future), i + 2);
        expect(live, 1);
      }
      expect(disposed, 100);
      expect(calls, 101);
    },
  );

  test('password and consent requirements block a bound session read', () {
    for (final next in [
      _auth().copyWith(passwordChangeRequired: true),
      _auth().copyWith(privacyConsentRequired: true),
      const PosAuthState(),
    ]) {
      expect(operationScopeFromAuth(next), isNull);
    }
    final data = FutureProvider<int>((ref) async {
      watchOperationScope(ref);
      return 1;
    });
    container.read(auth.notifier).state = const PosAuthState();
    expect(
      container.read(data.future),
      throwsA(isA<OperationScopeUnavailable>()),
    );
  });

  test(
    'old future cannot overwrite the new actor and logout sends no read',
    () async {
      final requests = <Completer<String>>[];
      final data = FutureProvider<String>((ref) {
        watchOperationScope(ref);
        final pending = Completer<String>();
        requests.add(pending);
        return pending.future;
      });
      final sub = container.listen(data, (_, __) {});
      addTearDown(sub.close);
      container.read(data);
      container.read(auth.notifier).state = _auth(actor: 'actor-b');
      final current = container.read(data.future);
      expect(requests, hasLength(2));
      requests.last.complete('actor-b-result');
      expect(await current, 'actor-b-result');
      requests.first.complete('actor-a-result');
      await container.pump();
      expect(container.read(data).requireValue, 'actor-b-result');
      container.read(auth.notifier).state = const PosAuthState();
      await expectLater(
        container.read(data.future),
        throwsA(isA<OperationScopeUnavailable>()),
      );
      expect(requests, hasLength(2));
    },
  );

  for (final issueQueue in [false, true]) {
    for (final transition in ['actor', 'store', 'permissions', 'logout']) {
      test(
        'QC ${issueQueue ? 'issues' : 'followups'} drops old $transition state',
        () async {
          final Object old;
          final Future<void> pending;
          if (issueQueue) {
            final n = container.read(qcIssueQueueProvider.notifier);
            old = n;
            pending = n.load('store-a');
          } else {
            final n = container.read(qcFollowupProvider.notifier);
            old = n;
            pending = n.load('store-a');
          }
          container.read(auth.notifier).state = switch (transition) {
            'actor' => _auth(actor: 'actor-b'),
            'store' => _auth(store: 'store-b'),
            'permissions' => _auth(permissions: []),
            _ => const PosAuthState(),
          };
          final replacement = issueQueue
              ? container.read(qcIssueQueueProvider.notifier)
              : container.read(qcFollowupProvider.notifier);
          expect(replacement, isNot(same(old)));
          service.reads.single.complete([
            {'id': 'old-private-data'},
          ]);
          await pending;
          if (issueQueue) {
            expect(container.read(qcIssueQueueProvider).issues, isEmpty);
          } else {
            expect(container.read(qcFollowupProvider).followups, isEmpty);
          }
          expect(service.reads, hasLength(1));
        },
      );
    }
  }

  test(
    'confirmed follow-up keeps result but does not reload after actor change',
    () async {
      final n = container.read(qcFollowupProvider.notifier);
      final read = n.load('store-a');
      service.reads.single.complete([]);
      await read;
      final write = n.createFollowup(
        storeId: 'store-a',
        sourceCheckId: 'check',
      );
      container.read(auth.notifier).state = _auth(actor: 'actor-b');
      container.read(qcFollowupProvider);
      service.writes.single.complete();
      expect(await write, isTrue);
      expect(service.reads, hasLength(1));
      expect(container.read(qcFollowupProvider).followups, isEmpty);
    },
  );
}
