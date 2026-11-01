/// Identity is supplied from trusted session/profile state, never user input.
/// Query parameters belong in a separate query key, not the actor identity.
class OperationScope {
  const OperationScope({
    required this.actorId,
    required this.storeId,
    required this.role,
    required this.authorizationRevision,
    this.legalEntityId,
  });

  final String actorId;
  final String? legalEntityId;
  final String? storeId;
  final String role;
  final String authorizationRevision;

  @override
  bool operator ==(Object other) =>
      other is OperationScope &&
      actorId == other.actorId &&
      legalEntityId == other.legalEntityId &&
      storeId == other.storeId &&
      role == other.role &&
      authorizationRevision == other.authorizationRevision;

  @override
  int get hashCode =>
      Object.hash(actorId, legalEntityId, storeId, role, authorizationRevision);
}

enum CommandStatus { confirmed, queued, unknown, rejected }

/// Outcomes describe the original write scope even after navigation/logout.
/// They never encode whether a later screen refresh succeeded.
class CommandOutcome<T> {
  const CommandOutcome.confirmed({
    required this.operationId,
    required this.scope,
    required this.value,
    required String resultId,
  }) : status = CommandStatus.confirmed,
       evidenceId = resultId,
       recoveryKey = null,
       rejectionCode = null;

  const CommandOutcome.queued({
    required this.operationId,
    required this.scope,
    required String durableEntryId,
    required this.recoveryKey,
  }) : status = CommandStatus.queued,
       evidenceId = durableEntryId,
       value = null,
       rejectionCode = null;

  const CommandOutcome.unknown({
    required this.operationId,
    required this.scope,
    required this.recoveryKey,
  }) : status = CommandStatus.unknown,
       evidenceId = null,
       value = null,
       rejectionCode = null;

  const CommandOutcome.rejected({
    required this.operationId,
    required this.scope,
    required this.rejectionCode,
  }) : status = CommandStatus.rejected,
       evidenceId = null,
       recoveryKey = null,
       value = null;

  final CommandStatus status;
  final String operationId;
  final OperationScope scope;
  final T? value;
  final String? evidenceId;
  final String? recoveryKey;
  final String? rejectionCode;

  /// Unknown writes require result reconciliation, not a fresh command ID.
  bool get requiresReconciliation => status == CommandStatus.unknown;
}

enum ReadFreshness { fresh, stale, loading, failed }

/// A successful empty result is fresh; failure never creates an empty success.
class ScopedReadValue<T> {
  const ScopedReadValue({
    required this.freshness,
    required this.scope,
    required this.queryKey,
    this.value,
    this.error,
    this.confirmedAt,
  });

  final ReadFreshness freshness;
  final OperationScope scope;
  final Object queryKey;
  final T? value;
  final Object? error;
  final DateTime? confirmedAt;
}
