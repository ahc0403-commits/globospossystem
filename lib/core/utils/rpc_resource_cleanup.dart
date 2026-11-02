import 'dart:async';

/// Constant-size diagnostics, independent of business command results. Never
/// retain errors, payloads, credentials or an unbounded event list here.
abstract final class RpcResourceDiagnostics {
  static int _cleanupFailures = 0;
  static int _cleanupTimeouts = 0;
  static int get cleanupFailures => _cleanupFailures;
  static int get cleanupTimeouts => _cleanupTimeouts;

  static void _failure({required bool timeout}) {
    if (_cleanupFailures < 1000000) _cleanupFailures++;
    if (timeout && _cleanupTimeouts < 1000000) _cleanupTimeouts++;
  }
}

/// PostgrestClient owns a native JSON isolate unless explicitly shared. Closing
/// its HTTP wrapper alone does not stop that worker. A cleanup failure must not
/// reinterpret a confirmed write as failed/queued or replace its original error.
Future<void> disposeRpcJsonWorker(
  Future<void> Function() dispose, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  try {
    await dispose().timeout(timeout);
  } on TimeoutException {
    RpcResourceDiagnostics._failure(timeout: true);
  } catch (_) {
    RpcResourceDiagnostics._failure(timeout: false);
  }
}
