import 'dart:async';

/// Serializes refresh work and retains at most one latest follow-up. A caller
/// waits for the drained queue, including changes received during an active read.
class CoalescedRefresh {
  Future<void> Function()? _pending;
  Future<void>? _running;
  bool _disposed = false;

  Future<void> run(Future<void> Function() refresh) {
    if (_disposed) return Future.value();
    _pending = refresh;
    if (_running != null) return _running!;
    final completion = Completer<void>();
    _running = completion.future;
    unawaited(_drain(completion));
    return completion.future;
  }

  Future<void> _drain(Completer<void> completion) async {
    Object? failure;
    StackTrace? trace;
    try {
      while (!_disposed && _pending != null) {
        final refresh = _pending!;
        _pending = null;
        try {
          await refresh();
        } catch (error, stack) {
          failure ??= error;
          trace ??= stack;
        }
      }
    } finally {
      _running = null;
      if (failure == null) {
        completion.complete();
      } else {
        completion.completeError(failure, trace);
      }
    }
  }

  void dispose() {
    _disposed = true;
    _pending = null;
  }
}
