import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/connectivity_service.dart';
import 'package:http/http.dart' as http;

void main() {
  group('connectivity classification', () {
    test('a server timeout never becomes an internet outage', () {
      final machine = ConnectivityStateMachine();

      final state = machine.record(
        const ConnectivityProbeResult.failed(ConnectivityFailureKind.server),
      );

      expect(state.kind, ServiceConnectivityKind.serverDegraded);
      expect(state.canAttemptOnlineWork, isTrue);
      expect(state.hasConfirmedNetworkOutage, isFalse);
    });

    test('requires two consecutive transport failures before offline', () {
      final machine = ConnectivityStateMachine();
      machine.record(
        const ConnectivityProbeResult.reachable(),
        now: DateTime.utc(2026, 9, 19, 1),
      );

      final first = machine.record(
        const ConnectivityProbeResult.failed(ConnectivityFailureKind.network),
      );
      final second = machine.record(
        const ConnectivityProbeResult.failed(ConnectivityFailureKind.network),
      );

      expect(first.kind, ServiceConnectivityKind.online);
      expect(first.canAttemptOnlineWork, isTrue);
      expect(second.kind, ServiceConnectivityKind.networkUnavailable);
      expect(second.canAttemptOnlineWork, isFalse);
    });

    test('success clears transport failures and records recovery time', () {
      final machine = ConnectivityStateMachine();
      machine.record(
        const ConnectivityProbeResult.failed(ConnectivityFailureKind.network),
      );
      machine.record(
        const ConnectivityProbeResult.failed(ConnectivityFailureKind.network),
      );
      final recoveredAt = DateTime.utc(2026, 9, 19, 2);

      final state = machine.record(
        const ConnectivityProbeResult.reachable(statusCode: 200),
        now: recoveredAt,
      );

      expect(state.kind, ServiceConnectivityKind.online);
      expect(state.consecutiveNetworkFailures, 0);
      expect(state.lastSuccessAt, recoveredAt);
      expect(state.lastStatusCode, 200);
    });

    test('auth failure blocks online-only work without claiming offline', () {
      final state = ConnectivityStateMachine().record(
        const ConnectivityProbeResult.failed(
          ConnectivityFailureKind.auth,
          statusCode: 401,
        ),
      );

      expect(state.kind, ServiceConnectivityKind.authRequired);
      expect(state.canAttemptOnlineWork, isFalse);
      expect(state.hasConfirmedNetworkOutage, isFalse);
    });
  });

  group('connectivity probe scheduling', () {
    test('timeout is published as degraded and remains attemptable', () async {
      final service = ConnectivityService(
        probe: () => throw TimeoutException('slow server'),
        random: Random(1),
      );
      final next = service.stream.first;

      await service.refresh();
      final state = await next;

      expect(state.kind, ServiceConnectivityKind.serverDegraded);
      expect(state.canAttemptOnlineWork, isTrue);
      await service.dispose();
    });

    test('client transport errors need two probes before offline', () async {
      final service = ConnectivityService(
        probe: () => throw http.ClientException('network down'),
        random: Random(1),
      );
      final states = <ServiceConnectivityState>[];
      final subscription = service.stream.listen(states.add);

      await service.refresh();
      await service.refresh();

      expect(states, hasLength(2));
      expect(states.first.kind, ServiceConnectivityKind.serverDegraded);
      expect(states.last.kind, ServiceConnectivityKind.networkUnavailable);
      await subscription.cancel();
      await service.dispose();
    });

    test('overlapping refreshes coalesce to one bounded follow-up', () async {
      final completers = <Completer<ConnectivityProbeResult>>[];
      var calls = 0;
      final service = ConnectivityService(
        probe: () {
          calls += 1;
          final completer = Completer<ConnectivityProbeResult>();
          completers.add(completer);
          return completer.future;
        },
        random: Random(1),
      );

      final first = service.refresh();
      service.refresh();
      service.refresh();
      expect(calls, 1);

      completers.first.complete(
        const ConnectivityProbeResult.reachable(statusCode: 200),
      );
      await first;
      await Future<void>.delayed(Duration.zero);
      expect(calls, 2);

      completers.last.complete(
        const ConnectivityProbeResult.reachable(statusCode: 200),
      );
      await Future<void>.delayed(Duration.zero);
      expect(calls, 2);
      await service.dispose();
    });
  });
}
