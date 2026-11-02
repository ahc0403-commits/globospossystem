import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../utils/operation_contract.dart';

/// A client session/view lifetime, not a replacement for server authorization.
/// The monotonically increasing generation also distinguishes A → B → A.
class OperationScopeSnapshot {
  const OperationScopeSnapshot({
    required this.generation,
    required this.scope,
    required this.isBound,
  });

  final int generation;
  final OperationScope? scope;
  final bool isBound;
}

class OperationScopeNotifier extends StateNotifier<OperationScopeSnapshot> {
  OperationScopeNotifier({bool isBound = false})
    : super(
        OperationScopeSnapshot(generation: 0, scope: null, isBound: isBound),
      );

  void publish(OperationScope? scope) {
    if (!mounted || state.scope == scope) return;
    state = OperationScopeSnapshot(
      generation: state.generation + 1,
      scope: scope,
      isBound: state.isBound,
    );
  }
}

/// The application root binds this to trusted Auth/profile state. The unbound
/// default lets isolated domain tests inject services without initializing Auth.
final operationScopeProvider =
    StateNotifierProvider<OperationScopeNotifier, OperationScopeSnapshot>(
      (ref) => OperationScopeNotifier(),
    );

class OperationScopeUnavailable implements Exception {
  const OperationScopeUnavailable();

  @override
  String toString() => 'OPERATION_SESSION_SCOPE_UNAVAILABLE';
}

/// Watch before starting a read. Riverpod discards results from the previous
/// generation; signed-out/blocked bound sessions cannot start another request.
OperationScopeSnapshot watchOperationScope(Ref ref) {
  final snapshot = ref.watch(operationScopeProvider);
  if (snapshot.isBound && snapshot.scope == null) {
    throw const OperationScopeUnavailable();
  }
  return snapshot;
}
