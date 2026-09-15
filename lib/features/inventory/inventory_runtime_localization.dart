import '../../l10n/app_localizations.dart';

/// Converts provider-owned inventory workflow copy into the active UI locale.
///
/// Inventory providers keep stable English semantic phrases for workflow and
/// test decisions. UI code must pass those phrases through this function. A
/// non-English locale never receives the provider phrase as a fallback.
String localizeInventoryRuntimeText(AppLocalizations l10n, String rawText) {
  final text = rawText.trim();
  if (text.isEmpty) return text;

  final normalized = text.toLowerCase().replaceAll('_', ' ');
  final exact = _localizeExactInventoryRuntimeText(l10n, normalized);
  if (exact != null) return exact;

  final priceDrift = RegExp(
    r'^price drift (stable|up|down) \(?([0-9.]+)%\)?$',
  ).firstMatch(normalized);
  if (priceDrift != null) {
    final direction = priceDrift.group(1)!;
    final percent = priceDrift.group(2)!;
    return switch (direction) {
      'up' => l10n.inventoryRuntimePriceDriftUp(percent),
      'down' => l10n.inventoryRuntimePriceDriftDown(percent),
      _ => l10n.inventoryRuntimePriceDriftStable(percent),
    };
  }

  if (normalized.startsWith('supplier risk ')) {
    final state = _containsAny(normalized, const ['price up', 'lead overdue'])
        ? l10n.inventoryRuntimeStateCritical
        : _containsAny(normalized, const ['receipt pending', 'lead tight'])
        ? l10n.inventoryRuntimeStateWatch
        : l10n.inventoryRuntimeStateComplete;
    return l10n.inventoryRuntimeStatusValue(
      l10n.inventoryRuntimeSubjectSupplier,
      state,
    );
  }

  final receivedLines = RegExp(
    r'^received lines ([0-9]+)(?: / ([0-9]+))?$',
  ).firstMatch(normalized);
  if (receivedLines != null) {
    final value = receivedLines.group(2) == null
        ? receivedLines.group(1)!
        : '${receivedLines.group(1)} / ${receivedLines.group(2)}';
    return l10n.inventoryRuntimeLabeledValue(
      l10n.inventoryRuntimeMetricReceived,
      value,
    );
  }

  final remainingLines = RegExp(
    r'^remaining lines ([0-9]+)(?: / ([0-9.]+) base)?$',
  ).firstMatch(normalized);
  if (remainingLines != null) {
    final value = remainingLines.group(2) == null
        ? remainingLines.group(1)!
        : '${remainingLines.group(1)} / ${remainingLines.group(2)}';
    return l10n.inventoryRuntimeLabeledValue(
      l10n.inventoryRuntimeMetricRemaining,
      value,
    );
  }

  final leadingCount = RegExp(r'^([0-9]+) ').firstMatch(normalized)?.group(1);
  if (leadingCount != null) {
    if (normalized.contains('blocker')) {
      return '${l10n.inventoryRuntimeLabeledValue(l10n.inventoryRuntimeMetricOpenBlockers, leadingCount)}. ${l10n.inventoryRuntimeBlockedGuidance}';
    }
    if (normalized.contains('attention')) {
      return '${l10n.inventoryRuntimeLabeledValue(l10n.inventoryRuntimeMetricAttentionLines, leadingCount)}. ${l10n.inventoryRuntimeSupplierGuidance}';
    }
    if (normalized.contains('purchase order')) {
      return '${l10n.inventoryRuntimeLabeledValue(l10n.inventoryRuntimeSubjectPurchaseOrder, leadingCount)}. ${l10n.inventoryRuntimeGeneralGuidance}';
    }
  }

  final locale = l10n.localeName.split(RegExp('[-_]')).first.toLowerCase();
  if (locale == 'en') return text;

  if (_containsAny(normalized, const [
    'failed',
    'failure',
    'error',
    'timeout',
    'no permission',
    'no longer exists',
    'not found',
  ])) {
    return l10n.inventoryRuntimeActionFailed;
  }
  if (normalized.contains('cancel')) {
    return l10n.inventoryRuntimeActionCancelled;
  }
  if (_containsAny(normalized, const [
    'refresh',
    'retry',
    'unknown outcome',
    'last attempt',
  ])) {
    return l10n.inventoryRuntimeRefreshGuidance;
  }
  if (_containsAny(normalized, const [
    'select ',
    'selection',
    'load a tracked',
    'no selected',
    'waiting selected',
  ])) {
    return l10n.inventoryRuntimeSelectionGuidance;
  }
  if (_containsAny(normalized, const ['recommendation', 'snapshot'])) {
    return l10n.inventoryRuntimeSnapshotGuidance;
  }
  if (_containsAny(normalized, const [
    'verification',
    'fully received',
    'received / closed',
    'received and closed',
    'runtime closure is complete',
  ])) {
    return l10n.inventoryRuntimeVerificationGuidance;
  }
  if (_containsAny(normalized, const [
    'supplier',
    'arrival',
    'lead-time',
    'overdue',
    'delayed',
  ])) {
    return l10n.inventoryRuntimeSupplierGuidance;
  }
  if (_containsAny(normalized, const ['approval', 'office', 'handoff'])) {
    return l10n.inventoryRuntimeApprovalGuidance;
  }
  if (_containsAny(normalized, const [
    'blocked',
    'not receivable',
    'unavailable',
    'hard stop',
  ])) {
    return l10n.inventoryRuntimeBlockedGuidance;
  }
  if (_containsAny(normalized, const [
    'receiv',
    'receipt',
    'inbound',
    'stock',
  ])) {
    return l10n.inventoryRuntimeReceivingGuidance;
  }
  if (_containsAny(normalized, const [
    'confirmed',
    'accepted',
    'saved',
    'succeeded',
  ])) {
    return l10n.inventoryRuntimeActionSucceeded;
  }
  return l10n.inventoryRuntimeTranslationMissing;
}

String? _localizeExactInventoryRuntimeText(
  AppLocalizations l10n,
  String normalized,
) {
  String status(String subject, String state) =>
      l10n.inventoryRuntimeStatusValue(subject, state);

  return switch (normalized) {
    'submitted' || 'office returned' => status(
      l10n.inventoryRuntimeSubjectApproval,
      l10n.inventoryRuntimeStatePending,
    ),
    'office approved' => status(
      l10n.inventoryRuntimeSubjectApproval,
      l10n.inventoryRuntimeStateApproved,
    ),
    'ordered' => status(
      l10n.inventoryRuntimeSubjectReceiving,
      l10n.inventoryRuntimeStateReady,
    ),
    'office rejected' => status(
      l10n.inventoryRuntimeSubjectApproval,
      l10n.inventoryRuntimeStateBlocked,
    ),
    'ready to approve' ||
    'ready office handoff' ||
    'office handoff now' => status(
      l10n.inventoryRuntimeSubjectApproval,
      l10n.inventoryRuntimeStateReady,
    ),
    'approved' => status(
      l10n.inventoryRuntimeSubjectApproval,
      l10n.inventoryRuntimeStateApproved,
    ),
    'approval blocked' || 'approval pending' => status(
      l10n.inventoryRuntimeSubjectApproval,
      normalized.endsWith('blocked')
          ? l10n.inventoryRuntimeStateBlocked
          : l10n.inventoryRuntimeStatePending,
    ),
    'ready to receive' ||
    'ready to receive now' ||
    'ready confirm receipt' => status(
      l10n.inventoryRuntimeSubjectReceiving,
      l10n.inventoryRuntimeStateReady,
    ),
    'received' ||
    'confirmed' ||
    'received / closed' ||
    'received and closed' ||
    'received complete' ||
    'remaining lines clear' => status(
      l10n.inventoryRuntimeSubjectReceiving,
      l10n.inventoryRuntimeStateComplete,
    ),
    'receiving blocked' => status(
      l10n.inventoryRuntimeSubjectReceiving,
      l10n.inventoryRuntimeStateBlocked,
    ),
    'pending' ||
    'draft' ||
    'partially received' ||
    'partially_received' => status(
      l10n.inventoryRuntimeSubjectReceiving,
      l10n.inventoryRuntimeStatePending,
    ),
    'cancelled' => l10n.inventoryRuntimeStateCancelled,
    'recommendation ready' => status(
      l10n.inventoryRuntimeSubjectRecommendation,
      l10n.inventoryRuntimeStateReady,
    ),
    'recommendation running' => status(
      l10n.inventoryRuntimeSubjectRecommendation,
      l10n.inventoryRuntimeStateRunning,
    ),
    'recommendation blocked' => status(
      l10n.inventoryRuntimeSubjectRecommendation,
      l10n.inventoryRuntimeStateBlocked,
    ),
    'recommendation idle' => status(
      l10n.inventoryRuntimeSubjectRecommendation,
      l10n.inventoryRuntimeStateIdle,
    ),
    'latest snapshot loading' => status(
      l10n.inventoryRuntimeSubjectSnapshot,
      l10n.inventoryRuntimeStateLoading,
    ),
    'latest snapshot blocked' => status(
      l10n.inventoryRuntimeSubjectSnapshot,
      l10n.inventoryRuntimeStateBlocked,
    ),
    'latest snapshot missing' => status(
      l10n.inventoryRuntimeSubjectSnapshot,
      l10n.inventoryRuntimeStateMissing,
    ),
    'latest snapshot empty' => status(
      l10n.inventoryRuntimeSubjectSnapshot,
      l10n.inventoryRuntimeStateEmpty,
    ),
    'latest snapshot visible' => status(
      l10n.inventoryRuntimeSubjectSnapshot,
      l10n.inventoryRuntimeStateVisible,
    ),
    'po creation ready' => status(
      l10n.inventoryRuntimeSubjectPurchaseOrder,
      l10n.inventoryRuntimeStateReady,
    ),
    'po creation running' => status(
      l10n.inventoryRuntimeSubjectPurchaseOrder,
      l10n.inventoryRuntimeStateRunning,
    ),
    'po creation blocked' => status(
      l10n.inventoryRuntimeSubjectPurchaseOrder,
      l10n.inventoryRuntimeStateBlocked,
    ),
    'po creation waiting snapshot' ||
    'po creation waiting supplier-qualified lines' ||
    'selected po runtime pending' => status(
      l10n.inventoryRuntimeSubjectPurchaseOrder,
      l10n.inventoryRuntimeStatePending,
    ),
    'healthy' || 'stable' || 'normal' => l10n.inventoryRuntimeStateComplete,
    'watch' || 'warning' || 'risk' => l10n.inventoryRuntimeStateWatch,
    'critical' || 'danger' => l10n.inventoryRuntimeStateCritical,
    'price drift unavailable' => l10n.inventoryRuntimePriceDriftUnavailable,
    'lead-time risk complete' => l10n.inventoryRuntimeLeadTimeComplete,
    'lead-time risk unavailable' => l10n.inventoryRuntimeLeadTimeUnavailable,
    'lead-time risk overdue' => l10n.inventoryRuntimeLeadTimeOverdue,
    'lead-time risk tight' => l10n.inventoryRuntimeLeadTimeTight,
    'lead-time risk on track' => l10n.inventoryRuntimeLeadTimeOnTrack,
    'supplier risk summary unavailable' =>
      l10n.inventoryRuntimeSupplierRiskUnavailable,
    'order attention complete' => l10n.inventoryRuntimeOrderAttentionComplete,
    'order attention escalation' =>
      l10n.inventoryRuntimeOrderAttentionEscalation,
    'order attention watch' => l10n.inventoryRuntimeOrderAttentionWatch,
    'order attention stable' => l10n.inventoryRuntimeOrderAttentionStable,
    'order attention unavailable' =>
      l10n.inventoryRuntimeOrderAttentionUnavailable,
    'attention pending' ||
    'ready waiting backend' ||
    'waiting backend' => status(
      l10n.inventoryRuntimeSubjectRuntime,
      l10n.inventoryRuntimeStatePending,
    ),
    'critical follow-up' ||
    'escalation open' => l10n.inventoryRuntimeStateCritical,
    'follow-up open' ||
    'lead tight' ||
    'price up' => l10n.inventoryRuntimeStateWatch,
    'stable queue' ||
    'stale none' ||
    'mismatch stable' ||
    'lead complete' ||
    'lead on track' ||
    'on track' ||
    'price stable' ||
    'price down' => l10n.inventoryRuntimeStateComplete,
    'last runtime state none yet' => status(
      l10n.inventoryRuntimeSubjectRuntime,
      l10n.inventoryRuntimeStateIdle,
    ),
    'operational phase runtime review' ||
    'pos keeps the runtime boundary visible, but the current backend state still needs review before any operator action becomes meaningful.' ||
    'no purchase-order reconciliation drift is visible yet because the current store-scoped queue has not opened any tracked purchase orders.' ||
    'continue monitoring recent purchase orders' ||
    'continue read-only monitoring' => l10n.inventoryRuntimeGeneralGuidance,
    'review the top attention lines before treating the purchase order as stable.' ||
    'review top attention items' ||
    'this line is moving, but it still needs watch-level review before operators treat it as stable.' ||
    'this line is currently visible for monitoring, but it does not carry the strongest operational runtime pressure.' =>
      l10n.inventoryRuntimeSupplierGuidance,
    _ => null,
  };
}

bool _containsAny(String value, List<String> needles) =>
    needles.any(value.contains);
