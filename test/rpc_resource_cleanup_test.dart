import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/utils/rpc_resource_cleanup.dart';

void main() {
  test(
    'a JSON cleanup failure cannot change an already confirmed write',
    () async {
      final before = RpcResourceDiagnostics.cleanupFailures;
      Future<String> command() async {
        try {
          return 'confirmed-original-result';
        } finally {
          await disposeRpcJsonWorker(
            () async => throw StateError('cleanup failed'),
          );
        }
      }

      expect(await command(), 'confirmed-original-result');
      expect(RpcResourceDiagnostics.cleanupFailures, before + 1);
    },
  );

  test(
    'cleanup preserves the original rejected/uncertain command error',
    () async {
      final original = TimeoutException('original transport uncertainty');
      Future<void> command() async {
        try {
          throw original;
        } finally {
          await disposeRpcJsonWorker(
            () async => throw StateError('cleanup failed'),
          );
        }
      }

      await expectLater(command(), throwsA(same(original)));
    },
  );

  test(
    'stalled cleanup has a finite budget without discarding confirmation',
    () async {
      final pending = Completer<void>();
      final before = RpcResourceDiagnostics.cleanupTimeouts;
      await disposeRpcJsonWorker(
        () => pending.future,
        timeout: const Duration(milliseconds: 5),
      );
      expect(RpcResourceDiagnostics.cleanupTimeouts, before + 1);
      pending.complete();
    },
  );

  test(
    'successful cleanup is called once and does not count a failure',
    () async {
      var calls = 0;
      final before = RpcResourceDiagnostics.cleanupFailures;
      await disposeRpcJsonWorker(() async {
        calls++;
      });
      expect(calls, 1);
      expect(RpcResourceDiagnostics.cleanupFailures, before);
    },
  );
}
