import 'dart:convert';

// 배달 정산 모델
// Deliberry → POS 정산 연동 데이터 모델
// 관련 문서: Deliberry볼트/Integration/POS-SETTLEMENT.md

// ─── 주문 피드 ──────────────────────────────

class DeliberryPosOrderFeedRequest {
  const DeliberryPosOrderFeedRequest({this.limit = 100, this.cursor});

  final int limit;
  final DeliberryOrderFeedCursor? cursor;

  Uri toUri(Uri functionsBaseUri) {
    final basePath = functionsBaseUri.path.endsWith('/')
        ? functionsBaseUri.path.substring(0, functionsBaseUri.path.length - 1)
        : functionsBaseUri.path;

    return functionsBaseUri.replace(
      path: '$basePath/pos-integration/orders',
      queryParameters: {
        'limit': limit.toString(),
        if (cursor != null) ...{
          'cursor_updated_at': cursor!.updatedAt,
          'cursor_id': cursor!.id,
        },
      },
    );
  }

  Map<String, String> authorizationHeaders(String posTerminalToken) {
    return {'Authorization': 'Bearer $posTerminalToken'};
  }
}

class DeliberryPosOrderFeedPage {
  const DeliberryPosOrderFeedPage({
    required this.items,
    required this.nextCursor,
  });

  final List<DeliberryPosOrderFeedOrder> items;
  final DeliberryOrderFeedCursor? nextCursor;

  factory DeliberryPosOrderFeedPage.fromJson(Map<String, dynamic> json) {
    final itemsRaw = json['items'];
    final cursorRaw = json['next_cursor'];

    return DeliberryPosOrderFeedPage(
      items: itemsRaw is List
          ? itemsRaw
                .whereType<Map>()
                .map(
                  (item) => DeliberryPosOrderFeedOrder.fromJson(
                    Map<String, dynamic>.from(item),
                  ),
                )
                .toList(growable: false)
          : const [],
      nextCursor: cursorRaw is Map
          ? DeliberryOrderFeedCursor.fromJson(
              Map<String, dynamic>.from(cursorRaw),
            )
          : null,
    );
  }
}

class DeliberryOrderFeedCursor {
  const DeliberryOrderFeedCursor({required this.updatedAt, required this.id});

  final String updatedAt;
  final String id;

  factory DeliberryOrderFeedCursor.fromJson(Map<String, dynamic> json) {
    return DeliberryOrderFeedCursor(
      updatedAt: json['updated_at']?.toString() ?? '',
      id: json['id']?.toString() ?? '',
    );
  }
}

class DeliberryPosOrderFeedOrder {
  const DeliberryPosOrderFeedOrder({
    required this.id,
    required this.updatedAt,
    required this.offlineCollectionAcknowledgment,
  });

  final String id;
  final String? updatedAt;
  final DeliberryOfflineCollectionAcknowledgment?
  offlineCollectionAcknowledgment;

  factory DeliberryPosOrderFeedOrder.fromJson(Map<String, dynamic> json) {
    final acknowledgmentRaw = json['offline_collection_acknowledgment'];

    return DeliberryPosOrderFeedOrder(
      id: (json['order_id'] ?? json['id'])?.toString() ?? '',
      updatedAt: json['updated_at']?.toString(),
      offlineCollectionAcknowledgment: acknowledgmentRaw is Map
          ? DeliberryOfflineCollectionAcknowledgment.fromJson(
              Map<String, dynamic>.from(acknowledgmentRaw),
            )
          : null,
    );
  }

  Map<String, dynamic> toOfflineCollectionOrderFields() {
    final acknowledgment = offlineCollectionAcknowledgment;
    if (acknowledgment == null || !acknowledgment.acknowledged) {
      return const {};
    }

    return {
      'offline_collection_acknowledged': true,
      'offline_collection_method': acknowledgment.method,
      'offline_collection_acknowledged_at': acknowledgment.acknowledgedAt,
      'offline_collection_acknowledged_by': acknowledgment.acknowledgedBy,
    };
  }
}

class DeliberryOfflineCollectionAcknowledgment {
  const DeliberryOfflineCollectionAcknowledgment({
    required this.acknowledged,
    required this.method,
    required this.acknowledgedAt,
    required this.acknowledgedBy,
  });

  final bool acknowledged;
  final String method;
  final String acknowledgedAt;
  final String acknowledgedBy;

  factory DeliberryOfflineCollectionAcknowledgment.fromJson(
    Map<String, dynamic> json,
  ) {
    return DeliberryOfflineCollectionAcknowledgment(
      acknowledged: json['acknowledged'] == true,
      method: json['payment_method']?.toString() ?? '',
      acknowledgedAt: json['acknowledged_at']?.toString() ?? '',
      acknowledgedBy: json['acknowledged_by']?.toString() ?? '',
    );
  }

  bool get isCashOrBankTransfer =>
      method == 'cash' || method == 'bank_transfer';
}

// ─── 운영 주문 D1 read model ─────────────────

const String deliberryOrderReceivedEvent = 'DELIBERRY_ORDER_RECEIVED';
const String deliberryOrderAcceptedEvent = 'DELIBERRY_ORDER_ACCEPTED';
const String deliberryOrderRejectedEvent = 'DELIBERRY_ORDER_REJECTED';
const String deliberryOrderReadyEvent = 'DELIBERRY_ORDER_READY';
const String deliberryOrderDeliveredEvent = 'DELIBERRY_ORDER_DELIVERED';
const String deliberryOrderCustomerCancelledEvent =
    'DELIBERRY_ORDER_CUSTOMER_CANCELLED';
const String deliberryOperationalPayloadVersion =
    'deliberry.operational_order.v1';
const String deliberryOperationalChannelId = 'DELIBERRY';

const Set<String> deliberryOperationalEventTypes = {
  deliberryOrderReceivedEvent,
  deliberryOrderAcceptedEvent,
  deliberryOrderRejectedEvent,
  deliberryOrderReadyEvent,
  deliberryOrderDeliveredEvent,
  deliberryOrderCustomerCancelledEvent,
};

enum DeliberryOperationalOrderStatus {
  newOrder,
  accepted,
  rejected,
  ready,
  delivered,
  customerCancelled,
}

String deliberryOperationalOrderStatusWireValue(
  DeliberryOperationalOrderStatus status,
) {
  return switch (status) {
    DeliberryOperationalOrderStatus.newOrder => 'new',
    DeliberryOperationalOrderStatus.accepted => 'accepted',
    DeliberryOperationalOrderStatus.rejected => 'rejected',
    DeliberryOperationalOrderStatus.ready => 'ready',
    DeliberryOperationalOrderStatus.delivered => 'delivered',
    DeliberryOperationalOrderStatus.customerCancelled => 'customer_cancelled',
  };
}

DeliberryOperationalOrderStatus deliberryOperationalOrderStatusFromWire(
  Object? value,
) {
  return switch (value?.toString()) {
    'accepted' => DeliberryOperationalOrderStatus.accepted,
    'rejected' => DeliberryOperationalOrderStatus.rejected,
    'ready' => DeliberryOperationalOrderStatus.ready,
    'delivered' => DeliberryOperationalOrderStatus.delivered,
    'customer_cancelled' ||
    'customer-cancelled' => DeliberryOperationalOrderStatus.customerCancelled,
    _ => DeliberryOperationalOrderStatus.newOrder,
  };
}

enum DeliberryOperationalOrderAction { accept, reject, ready }

String deliberryOperationalOrderActionEventType(
  DeliberryOperationalOrderAction action,
) {
  return switch (action) {
    DeliberryOperationalOrderAction.accept => deliberryOrderAcceptedEvent,
    DeliberryOperationalOrderAction.reject => deliberryOrderRejectedEvent,
    DeliberryOperationalOrderAction.ready => deliberryOrderReadyEvent,
  };
}

bool isDeliberryOperationalOrderTransitionAllowed({
  required DeliberryOperationalOrderStatus from,
  required DeliberryOperationalOrderStatus to,
}) {
  if (from == to) return true;

  return switch (from) {
    DeliberryOperationalOrderStatus.newOrder =>
      to == DeliberryOperationalOrderStatus.accepted ||
          to == DeliberryOperationalOrderStatus.rejected ||
          to == DeliberryOperationalOrderStatus.customerCancelled,
    DeliberryOperationalOrderStatus.accepted =>
      to == DeliberryOperationalOrderStatus.ready ||
          to == DeliberryOperationalOrderStatus.customerCancelled,
    DeliberryOperationalOrderStatus.ready =>
      to == DeliberryOperationalOrderStatus.delivered ||
          to == DeliberryOperationalOrderStatus.customerCancelled,
    DeliberryOperationalOrderStatus.rejected ||
    DeliberryOperationalOrderStatus.delivered ||
    DeliberryOperationalOrderStatus.customerCancelled => false,
  };
}

bool canPerformDeliberryOperationalOrderAction({
  required DeliberryOperationalOrderAction action,
  required String? role,
  required String activeStoreId,
  required String orderStoreId,
  Iterable<String> accessibleStoreIds = const [],
}) {
  if (activeStoreId.isEmpty || orderStoreId.isEmpty) return false;
  if (activeStoreId != orderStoreId) return false;
  if (accessibleStoreIds.isNotEmpty &&
      !accessibleStoreIds.contains(activeStoreId)) {
    return false;
  }

  final managerCanAct =
      role == 'admin' ||
      role == 'store_admin' ||
      role == 'brand_admin' ||
      role == 'super_admin';

  return switch (action) {
    DeliberryOperationalOrderAction.accept ||
    DeliberryOperationalOrderAction.reject => managerCanAct,
    DeliberryOperationalOrderAction.ready => managerCanAct || role == 'kitchen',
  };
}

enum DeliberryOperationalOrderTransitionIssue { staleEvent, illegalTransition }

class DeliberryOperationalOrderTransitionAnomaly {
  const DeliberryOperationalOrderTransitionAnomaly({
    required this.issue,
    required this.eventId,
    required this.externalOrderId,
    required this.storeId,
    required this.fromStatus,
    required this.toStatus,
    required this.eventSequence,
    required this.lastEventSequence,
  });

  final DeliberryOperationalOrderTransitionIssue issue;
  final String eventId;
  final String externalOrderId;
  final String storeId;
  final DeliberryOperationalOrderStatus fromStatus;
  final DeliberryOperationalOrderStatus? toStatus;
  final int eventSequence;
  final int lastEventSequence;
}

class DeliberryOperationalOrderItem {
  const DeliberryOperationalOrderItem({
    required this.name,
    required this.quantity,
    required this.unitPrice,
    this.sku,
    this.options = const [],
  });

  final String? sku;
  final String name;
  final int quantity;
  final double unitPrice;
  final List<String> options;

  factory DeliberryOperationalOrderItem.fromJson(Map<String, dynamic> json) {
    final optionsRaw = json['options'];
    return DeliberryOperationalOrderItem(
      sku: json['sku']?.toString(),
      name: json['name']?.toString() ?? '',
      quantity: json['quantity'] is int
          ? json['quantity'] as int
          : int.tryParse(json['quantity']?.toString() ?? '1') ?? 1,
      unitPrice: _toDouble(json['unit_price'] ?? json['price']),
      options: optionsRaw is List
          ? optionsRaw
                .map((option) => option.toString())
                .toList(growable: false)
          : const [],
    );
  }
}

class DeliberryOperationalOrder {
  const DeliberryOperationalOrder({
    required this.storeId,
    required this.externalOrderId,
    required this.status,
    required this.traceId,
    this.orderNo,
    this.stateVersion = 0,
    this.payloadVersion = deliberryOperationalPayloadVersion,
    this.channelId = deliberryOperationalChannelId,
    this.customerNote,
    this.customerName,
    this.grossAmount = 0,
    this.paymentStatus,
    this.paymentMethod,
    this.collectionMode,
    this.rejectReason,
    this.items = const [],
    this.sourceEventIds = const {},
    this.payload = const {},
    this.lastEventSequence = 0,
    this.createdAt,
    this.updatedAt,
  });

  final String storeId;
  final String externalOrderId;
  final DeliberryOperationalOrderStatus status;
  final String traceId;
  final String? orderNo;
  final int stateVersion;
  final String payloadVersion;
  final String channelId;
  final String? customerNote;
  final String? customerName;
  final double grossAmount;
  final String? paymentStatus;
  final String? paymentMethod;
  final String? collectionMode;
  final String? rejectReason;
  final List<DeliberryOperationalOrderItem> items;
  final Set<String> sourceEventIds;
  final Map<String, dynamic> payload;
  final int lastEventSequence;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  factory DeliberryOperationalOrder.fromJson(Map<String, dynamic> json) {
    final itemsRaw = json['items'];
    final sourceEventIdsRaw = json['source_event_ids'];

    return DeliberryOperationalOrder(
      storeId: (json['store_id'] ?? json['restaurant_id'])?.toString() ?? '',
      externalOrderId: json['external_order_id']?.toString() ?? '',
      status: deliberryOperationalOrderStatusFromWire(
        json['status'] ?? json['order_status'],
      ),
      traceId: _nonEmptyString(
        json['trace_id'],
        fallback:
            'deliberry:${(json['store_id'] ?? json['restaurant_id']) ?? ''}:${json['external_order_id'] ?? ''}',
      ),
      orderNo: (json['order_no'] ?? json['display_order_id'])?.toString(),
      stateVersion: _toInt(json['state_version']),
      payloadVersion: _nonEmptyString(
        json['payload_version'],
        fallback: deliberryOperationalPayloadVersion,
      ),
      channelId: _nonEmptyString(
        json['channel_id'],
        fallback: deliberryOperationalChannelId,
      ),
      customerNote: (json['customer_note'] ?? json['note'])?.toString(),
      customerName: json['customer_name']?.toString(),
      grossAmount: _toDouble(json['gross_amount'] ?? json['amount']),
      paymentStatus: json['payment_status']?.toString(),
      paymentMethod: json['payment_method']?.toString(),
      collectionMode:
          json['settlement_collection_mode']?.toString() ??
          json['collection_mode']?.toString(),
      rejectReason: json['reject_reason']?.toString(),
      items: itemsRaw is List
          ? itemsRaw
                .whereType<Map>()
                .map(
                  (item) => DeliberryOperationalOrderItem.fromJson(
                    Map<String, dynamic>.from(item),
                  ),
                )
                .toList(growable: false)
          : const [],
      sourceEventIds: sourceEventIdsRaw is List
          ? sourceEventIdsRaw
                .map((eventId) => eventId.toString())
                .where((eventId) => eventId.isNotEmpty)
                .toSet()
          : const {},
      payload: _toJsonObject(json['payload']),
      lastEventSequence:
          int.tryParse(json['last_event_sequence']?.toString() ?? '0') ?? 0,
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? ''),
      updatedAt: DateTime.tryParse(json['updated_at']?.toString() ?? ''),
    );
  }

  bool get createsPosRevenue => false;

  String get statusWireValue =>
      deliberryOperationalOrderStatusWireValue(status);

  bool isStaleEvent(DeliberryOperationalOrderEvent event) {
    return event.eventSequence > 0 &&
        lastEventSequence > 0 &&
        event.eventSequence <= lastEventSequence;
  }

  bool canApplyEvent(DeliberryOperationalOrderEvent event) {
    final targetStatus = event.targetStatus;
    if (event.hasStateError) return false;
    if (targetStatus == null) return true;
    if (isStaleEvent(event)) return false;
    return isDeliberryOperationalOrderTransitionAllowed(
      from: status,
      to: targetStatus,
    );
  }

  DeliberryOperationalOrder mergeEvent(DeliberryOperationalOrderEvent event) {
    if (event.storeId != storeId ||
        event.externalOrderId != externalOrderId ||
        sourceEventIds.contains(event.eventId)) {
      return this;
    }
    if (!canApplyEvent(event)) {
      return copyWith(sourceEventIds: {...sourceEventIds, event.eventId});
    }

    final nextStatus = event.targetStatus ?? status;

    return copyWith(
      status: nextStatus,
      stateVersion: stateVersion + (nextStatus == status ? 0 : 1),
      rejectReason: event.reason ?? rejectReason,
      sourceEventIds: {...sourceEventIds, event.eventId},
      payload: {...payload, ...event.payload},
      lastEventSequence: event.eventSequence > lastEventSequence
          ? event.eventSequence
          : lastEventSequence,
    );
  }

  DeliberryOperationalOrderEvent actionEvent({
    required DeliberryOperationalOrderAction action,
    required String eventId,
    required String actorId,
    required String role,
    required String activeStoreId,
    Iterable<String> accessibleStoreIds = const [],
    String? reason,
  }) {
    if (!canPerformDeliberryOperationalOrderAction(
      action: action,
      role: role,
      activeStoreId: activeStoreId,
      orderStoreId: storeId,
      accessibleStoreIds: accessibleStoreIds,
    )) {
      throw StateError('DELIBERRY_ORDER_ACTION_SCOPE_DENIED');
    }
    if (action == DeliberryOperationalOrderAction.reject &&
        (reason == null || reason.trim().isEmpty)) {
      throw StateError('DELIBERRY_ORDER_REJECT_REASON_REQUIRED');
    }

    return DeliberryOperationalOrderEvent(
      eventId: eventId,
      traceId: traceId,
      eventType: deliberryOperationalOrderActionEventType(action),
      storeId: storeId,
      externalOrderId: externalOrderId,
      payloadVersion: payloadVersion,
      channelId: channelId,
      actorId: actorId,
      reason: reason?.trim(),
      payload: {
        'order_status': statusWireValue,
        'external_order_id': externalOrderId,
        if (reason != null && reason.trim().isNotEmpty)
          'reject_reason': reason.trim(),
      },
    );
  }

  DeliberryOperationalOrder copyWith({
    DeliberryOperationalOrderStatus? status,
    int? stateVersion,
    String? rejectReason,
    Set<String>? sourceEventIds,
    Map<String, dynamic>? payload,
    int? lastEventSequence,
  }) {
    return DeliberryOperationalOrder(
      storeId: storeId,
      externalOrderId: externalOrderId,
      status: status ?? this.status,
      traceId: traceId,
      orderNo: orderNo,
      stateVersion: stateVersion ?? this.stateVersion,
      payloadVersion: payloadVersion,
      channelId: channelId,
      customerNote: customerNote,
      customerName: customerName,
      grossAmount: grossAmount,
      paymentStatus: paymentStatus,
      paymentMethod: paymentMethod,
      collectionMode: collectionMode,
      rejectReason: rejectReason ?? this.rejectReason,
      items: items,
      sourceEventIds: sourceEventIds ?? this.sourceEventIds,
      payload: payload ?? this.payload,
      lastEventSequence: lastEventSequence ?? this.lastEventSequence,
      createdAt: createdAt,
      updatedAt: updatedAt,
    );
  }
}

class DeliberryOperationalOrderEvent {
  const DeliberryOperationalOrderEvent({
    required this.eventId,
    required this.eventType,
    required this.storeId,
    required this.externalOrderId,
    this.traceId,
    this.payloadVersion = deliberryOperationalPayloadVersion,
    this.channelId = deliberryOperationalChannelId,
    this.status = 'pending',
    this.attemptCount = 0,
    this.eventSequence = 0,
    this.stateApplied = true,
    this.actorId,
    this.reason,
    this.stateError,
    this.lastError,
    this.payload = const {},
    this.eventOccurredAt,
    this.processedAt,
    this.deadLetterAt,
    this.createdAt,
  });

  final String eventId;
  final String eventType;
  final String storeId;
  final String externalOrderId;
  final String? traceId;
  final String payloadVersion;
  final String channelId;
  final String status;
  final int attemptCount;
  final int eventSequence;
  final bool stateApplied;
  final String? actorId;
  final String? reason;
  final String? stateError;
  final String? lastError;
  final Map<String, dynamic> payload;
  final DateTime? eventOccurredAt;
  final DateTime? processedAt;
  final DateTime? deadLetterAt;
  final DateTime? createdAt;

  bool get createsPosRevenue => false;
  bool get isRetryable => status == 'pending' || status == 'failed';
  bool get isDeadLetter => status == 'dead' || deadLetterAt != null;
  bool get hasStateError => stateError != null && stateError!.isNotEmpty;

  DeliberryOperationalOrderStatus? get targetStatus {
    return switch (eventType) {
      deliberryOrderReceivedEvent => DeliberryOperationalOrderStatus.newOrder,
      deliberryOrderAcceptedEvent => DeliberryOperationalOrderStatus.accepted,
      deliberryOrderRejectedEvent => DeliberryOperationalOrderStatus.rejected,
      deliberryOrderReadyEvent => DeliberryOperationalOrderStatus.ready,
      deliberryOrderDeliveredEvent => DeliberryOperationalOrderStatus.delivered,
      deliberryOrderCustomerCancelledEvent =>
        DeliberryOperationalOrderStatus.customerCancelled,
      _ => null,
    };
  }
}

class DeliberryOperationalOrderInbox {
  const DeliberryOperationalOrderInbox({
    this.ordersByScopedExternalId = const {},
    this.processedEventIds = const {},
    this.transitionAnomalies = const [],
  });

  final Map<String, DeliberryOperationalOrder> ordersByScopedExternalId;
  final Set<String> processedEventIds;
  final List<DeliberryOperationalOrderTransitionAnomaly> transitionAnomalies;

  List<DeliberryOperationalOrder> ordersForActiveStore(String activeStoreId) {
    return ordersByScopedExternalId.values
        .where((order) => order.storeId == activeStoreId)
        .toList(growable: false)
      ..sort((left, right) {
        final leftDate = left.updatedAt ?? left.createdAt;
        final rightDate = right.updatedAt ?? right.createdAt;
        if (leftDate == null && rightDate == null) {
          return left.externalOrderId.compareTo(right.externalOrderId);
        }
        if (leftDate == null) return 1;
        if (rightDate == null) return -1;
        return rightDate.compareTo(leftDate);
      });
  }

  int get posRevenueRowsCreated => ordersByScopedExternalId.values
      .where((order) => order.createsPosRevenue)
      .length;

  DeliberryOperationalReconciliationSummary reconcileActiveStore(
    String activeStoreId, {
    Iterable<String> expectedExternalOrderIds = const [],
  }) {
    return DeliberryOperationalReconciliationSummary.fromInbox(
      this,
      activeStoreId: activeStoreId,
      expectedExternalOrderIds: expectedExternalOrderIds,
    );
  }

  DeliberryOperationalOrderInbox applyEvent(
    DeliberryOperationalOrderEvent event,
  ) {
    if (processedEventIds.contains(event.eventId)) return this;

    final key = _scopedExternalOrderKey(event.storeId, event.externalOrderId);
    final existing = ordersByScopedExternalId[key];
    final anomaly = existing == null
        ? _initialTransitionAnomalyFor(event)
        : _transitionAnomalyFor(existing, event);
    final appliesInitialState =
        event.targetStatus == null ||
        event.targetStatus == DeliberryOperationalOrderStatus.newOrder;
    final nextOrder =
        existing?.mergeEvent(event) ??
        DeliberryOperationalOrder(
          storeId: event.storeId,
          externalOrderId: event.externalOrderId,
          status: appliesInitialState
              ? event.targetStatus ?? DeliberryOperationalOrderStatus.newOrder
              : DeliberryOperationalOrderStatus.newOrder,
          traceId:
              event.traceId ??
              'deliberry:${event.storeId}:${event.externalOrderId}',
          payloadVersion: event.payloadVersion,
          channelId: event.channelId,
          rejectReason: event.reason,
          sourceEventIds: {event.eventId},
          payload: event.payload,
          lastEventSequence: appliesInitialState ? event.eventSequence : 0,
          createdAt: event.createdAt,
          updatedAt: event.createdAt,
        );

    return DeliberryOperationalOrderInbox(
      ordersByScopedExternalId: {...ordersByScopedExternalId, key: nextOrder},
      processedEventIds: {...processedEventIds, event.eventId},
      transitionAnomalies: [
        ...transitionAnomalies,
        if (anomaly != null) anomaly,
      ],
    );
  }
}

String _scopedExternalOrderKey(String storeId, String externalOrderId) =>
    '$storeId::$externalOrderId';

DeliberryOperationalOrderTransitionAnomaly? _initialTransitionAnomalyFor(
  DeliberryOperationalOrderEvent event,
) {
  final targetStatus = event.targetStatus;
  if (targetStatus == null ||
      targetStatus == DeliberryOperationalOrderStatus.newOrder) {
    return null;
  }
  return DeliberryOperationalOrderTransitionAnomaly(
    issue: DeliberryOperationalOrderTransitionIssue.illegalTransition,
    eventId: event.eventId,
    externalOrderId: event.externalOrderId,
    storeId: event.storeId,
    fromStatus: DeliberryOperationalOrderStatus.newOrder,
    toStatus: targetStatus,
    eventSequence: event.eventSequence,
    lastEventSequence: 0,
  );
}

DeliberryOperationalOrderTransitionAnomaly? _transitionAnomalyFor(
  DeliberryOperationalOrder order,
  DeliberryOperationalOrderEvent event,
) {
  final targetStatus = event.targetStatus;
  if (event.hasStateError) {
    return DeliberryOperationalOrderTransitionAnomaly(
      issue: DeliberryOperationalOrderTransitionIssue.illegalTransition,
      eventId: event.eventId,
      externalOrderId: event.externalOrderId,
      storeId: event.storeId,
      fromStatus: order.status,
      toStatus: targetStatus,
      eventSequence: event.eventSequence,
      lastEventSequence: order.lastEventSequence,
    );
  }
  if (targetStatus == null) return null;
  if (order.isStaleEvent(event)) {
    return DeliberryOperationalOrderTransitionAnomaly(
      issue: DeliberryOperationalOrderTransitionIssue.staleEvent,
      eventId: event.eventId,
      externalOrderId: event.externalOrderId,
      storeId: event.storeId,
      fromStatus: order.status,
      toStatus: targetStatus,
      eventSequence: event.eventSequence,
      lastEventSequence: order.lastEventSequence,
    );
  }
  if (!isDeliberryOperationalOrderTransitionAllowed(
    from: order.status,
    to: targetStatus,
  )) {
    return DeliberryOperationalOrderTransitionAnomaly(
      issue: DeliberryOperationalOrderTransitionIssue.illegalTransition,
      eventId: event.eventId,
      externalOrderId: event.externalOrderId,
      storeId: event.storeId,
      fromStatus: order.status,
      toStatus: targetStatus,
      eventSequence: event.eventSequence,
      lastEventSequence: order.lastEventSequence,
    );
  }
  return null;
}

class DeliberryOperationalReconciliationSummary {
  const DeliberryOperationalReconciliationSummary({
    required this.activeStoreId,
    required this.orderCount,
    required this.processedEventCount,
    required this.revenueRowCount,
    required this.statusCounts,
    required this.staleEventCount,
    required this.illegalTransitionCount,
    required this.missingExternalOrderIds,
  });

  final String activeStoreId;
  final int orderCount;
  final int processedEventCount;
  final int revenueRowCount;
  final Map<DeliberryOperationalOrderStatus, int> statusCounts;
  final int staleEventCount;
  final int illegalTransitionCount;
  final List<String> missingExternalOrderIds;

  bool get hasStateMachineAnomalies =>
      staleEventCount > 0 || illegalTransitionCount > 0;

  bool get isFinanciallyBalanced => revenueRowCount == 0;

  factory DeliberryOperationalReconciliationSummary.fromInbox(
    DeliberryOperationalOrderInbox inbox, {
    required String activeStoreId,
    Iterable<String> expectedExternalOrderIds = const [],
  }) {
    final orders = inbox.ordersForActiveStore(activeStoreId);
    final statusCounts = {
      for (final status in DeliberryOperationalOrderStatus.values)
        status: orders.where((order) => order.status == status).length,
    };
    final actualExternalIds = orders
        .map((order) => order.externalOrderId)
        .toSet();
    final missingExternalOrderIds = expectedExternalOrderIds
        .where(
          (externalOrderId) => !actualExternalIds.contains(externalOrderId),
        )
        .toList(growable: false);
    final storeAnomalies = inbox.transitionAnomalies
        .where((anomaly) => anomaly.storeId == activeStoreId)
        .toList(growable: false);

    return DeliberryOperationalReconciliationSummary(
      activeStoreId: activeStoreId,
      orderCount: orders.length,
      processedEventCount: inbox.processedEventIds.length,
      revenueRowCount: inbox.posRevenueRowsCreated,
      statusCounts: statusCounts,
      staleEventCount: storeAnomalies
          .where(
            (anomaly) =>
                anomaly.issue ==
                DeliberryOperationalOrderTransitionIssue.staleEvent,
          )
          .length,
      illegalTransitionCount: storeAnomalies
          .where(
            (anomaly) =>
                anomaly.issue ==
                DeliberryOperationalOrderTransitionIssue.illegalTransition,
          )
          .length,
      missingExternalOrderIds: missingExternalOrderIds,
    );
  }
}

String _nonEmptyString(Object? value, {required String fallback}) {
  final candidate = value?.toString().trim();
  return candidate == null || candidate.isEmpty ? fallback : candidate;
}

// ─── 외부 매출 수금 분류 ───────────────────────

class DeliberryExternalSalePayload {
  const DeliberryExternalSalePayload({
    required this.settlementCollectionMode,
    required this.offlineCollectionAcknowledgment,
    required this.offlineCollectionMethod,
  });

  final String? settlementCollectionMode;
  final DeliberryOfflineCollectionAcknowledgment?
  offlineCollectionAcknowledgment;
  final String? offlineCollectionMethod;

  factory DeliberryExternalSalePayload.fromJson(Map<String, dynamic> json) {
    final acknowledgmentRaw = json['offline_collection_acknowledgment'];

    return DeliberryExternalSalePayload(
      settlementCollectionMode: json['settlement_collection_mode']?.toString(),
      offlineCollectionAcknowledgment: acknowledgmentRaw is Map
          ? DeliberryOfflineCollectionAcknowledgment.fromJson(
              Map<String, dynamic>.from(acknowledgmentRaw),
            )
          : null,
      offlineCollectionMethod:
          json['offline_collection_method']?.toString() ??
          json['collection_method']?.toString(),
    );
  }

  bool get isMerchantCollectedOffline =>
      settlementCollectionMode == 'merchant_collected_offline' ||
      offlineCollectionAcknowledgment != null;

  bool get excludesFromPlatformPayout {
    if (settlementCollectionMode == 'merchant_collected_offline') {
      return true;
    }

    final method =
        offlineCollectionAcknowledgment?.method ?? offlineCollectionMethod;
    return method == 'cash' || method == 'bank_transfer';
  }
}

class DeliberryExternalSale {
  const DeliberryExternalSale({
    required this.grossAmount,
    required this.orderStatus,
    required this.isRevenue,
    required this.payload,
  });

  final double grossAmount;
  final String orderStatus;
  final bool isRevenue;
  final DeliberryExternalSalePayload payload;

  factory DeliberryExternalSale.fromJson(Map<String, dynamic> json) {
    return DeliberryExternalSale(
      grossAmount: _toDouble(json['gross_amount']),
      orderStatus: json['order_status']?.toString() ?? '',
      isRevenue: json['is_revenue'] is bool
          ? json['is_revenue'] as bool
          : json['is_revenue']?.toString() != 'false',
      payload: DeliberryExternalSalePayload.fromJson(
        _toJsonObject(json['payload']),
      ),
    );
  }

  bool get isSettledRevenueCandidate => isRevenue && orderStatus == 'completed';

  bool get isMerchantCollectedOffline => payload.isMerchantCollectedOffline;

  bool get excludesFromPlatformPayout => payload.excludesFromPlatformPayout;
}

class DeliberrySettlementEstimate {
  const DeliberrySettlementEstimate({
    required this.grossTotal,
    required this.merchantOfflineCollectionTotal,
    required this.platformPayableGross,
    required this.platformCommission,
    required this.paymentFee,
    required this.totalDeductions,
    required this.netSettlement,
  });

  final double grossTotal;
  final double merchantOfflineCollectionTotal;
  final double platformPayableGross;
  final double platformCommission;
  final double paymentFee;
  final double totalDeductions;
  final double netSettlement;

  factory DeliberrySettlementEstimate.fromExternalSales(
    Iterable<DeliberryExternalSale> sales, {
    double platformCommissionRate = 0.015,
    double paymentFeeRate = 0.015,
  }) {
    double grossTotal = 0;
    double merchantOfflineCollectionTotal = 0;

    for (final sale in sales.where((sale) => sale.isSettledRevenueCandidate)) {
      grossTotal += sale.grossAmount;
      if (sale.excludesFromPlatformPayout) {
        merchantOfflineCollectionTotal += sale.grossAmount;
      }
    }

    grossTotal = _roundMoney(grossTotal);
    merchantOfflineCollectionTotal = _roundMoney(
      merchantOfflineCollectionTotal,
    );
    final platformPayableGross = _roundMoney(
      (grossTotal - merchantOfflineCollectionTotal).clamp(0, double.infinity),
    );
    final platformCommission = _roundMoney(
      platformPayableGross * platformCommissionRate,
    );
    final paymentFee = _roundMoney(platformPayableGross * paymentFeeRate);
    final totalDeductions = _roundMoney(
      merchantOfflineCollectionTotal + platformCommission + paymentFee,
    );

    return DeliberrySettlementEstimate(
      grossTotal: grossTotal,
      merchantOfflineCollectionTotal: merchantOfflineCollectionTotal,
      platformPayableGross: platformPayableGross,
      platformCommission: platformCommission,
      paymentFee: paymentFee,
      totalDeductions: totalDeductions,
      netSettlement: _roundMoney(grossTotal - totalDeductions),
    );
  }
}

// ─── 정산 차감 항목 ───────────────────────────

class DeliverySettlementItem {
  const DeliverySettlementItem({
    required this.id,
    required this.settlementId,
    required this.itemType,
    required this.amount,
    this.description,
    this.referenceRate,
    this.referenceBase,
    required this.createdAt,
  });

  final String id;
  final String settlementId;
  final String itemType;
  final double amount;
  final String? description;
  final double? referenceRate;
  final double? referenceBase;
  final DateTime createdAt;

  /// item_type → 한국어 라벨
  String get label => _itemTypeLabels[itemType] ?? itemType;

  factory DeliverySettlementItem.fromJson(Map<String, dynamic> json) {
    return DeliverySettlementItem(
      id: json['id'].toString(),
      settlementId: json['settlement_id'].toString(),
      itemType: json['item_type']?.toString() ?? '',
      amount: _toDouble(json['amount']),
      description: json['description']?.toString(),
      referenceRate: json['reference_rate'] != null
          ? _toDouble(json['reference_rate'])
          : null,
      referenceBase: json['reference_base'] != null
          ? _toDouble(json['reference_base'])
          : null,
      createdAt:
          DateTime.tryParse(json['created_at']?.toString() ?? '') ??
          DateTime.now(),
    );
  }
}

const Map<String, String> _itemTypeLabels = {
  'merchant_offline_collection': 'Merchant Offline Collection',
  'platform_commission': 'Platform Fee',
  'payment_fee': 'Payment Fee',
  'advertising': 'Ad Spend',
  'insight_report': 'Insight Report',
  'promo_subsidy': 'Promotion Subsidy',
  'delivery_subsidy': 'Delivery Fee Subsidy',
  'photo_service': 'Take Photo',
};

// ─── 정산 헤더 ──────────────────────────────

class DeliverySettlement {
  const DeliverySettlement({
    required this.id,
    required this.storeId,
    required this.periodLabel,
    required this.periodStart,
    required this.periodEnd,
    required this.grossTotal,
    required this.totalDeductions,
    required this.netSettlement,
    required this.status,
    this.receivedAt,
    this.notes,
    this.items = const [],
    this.orderCount = 0,
  });

  final String id;
  final String storeId;
  final String periodLabel;
  final DateTime periodStart;
  final DateTime periodEnd;
  final double grossTotal;
  final double totalDeductions;
  final double netSettlement;
  final String status;
  final DateTime? receivedAt;
  final String? notes;
  final List<DeliverySettlementItem> items;
  final int orderCount;

  /// 상태 배지
  String get statusEmoji => switch (status) {
    'pending' => '⏳',
    'calculated' => '📋',
    'received' => '✅',
    'disputed' => '⚠️',
    'adjusted' => '🔧',
    _ => '❓',
  };

  String get statusLabel => switch (status) {
    'pending' => 'Settlement Pending',
    'calculated' => 'Statement Generated',
    'received' => 'Settlement Complete',
    'disputed' => 'Dispute',
    'adjusted' => 'Adjustment Complete',
    _ => status,
  };

  bool get canConfirmReceived => status == 'calculated';

  /// v_settlement_summary 뷰에서 생성
  factory DeliverySettlement.fromJson(Map<String, dynamic> json) {
    final storeId = json['store_id'] ?? json['restaurant_id'];
    final itemsRaw = json['items'];
    List<DeliverySettlementItem> items = [];
    if (itemsRaw is List) {
      items = itemsRaw.map<DeliverySettlementItem>((e) {
        final map = Map<String, dynamic>.from(e);
        return DeliverySettlementItem(
          id: map['item_type']?.toString() ?? '',
          settlementId: '',
          itemType: map['item_type']?.toString() ?? '',
          amount: _toDouble(map['amount']),
          description: map['description']?.toString(),
          referenceRate: map['reference_rate'] != null
              ? _toDouble(map['reference_rate'])
              : null,
          referenceBase: null,
          createdAt: DateTime.now(),
        );
      }).toList();
    }

    return DeliverySettlement(
      id: json['id'].toString(),
      storeId: storeId.toString(),
      periodLabel: json['period_label']?.toString() ?? '',
      periodStart:
          DateTime.tryParse(json['period_start']?.toString() ?? '') ??
          DateTime.now(),
      periodEnd:
          DateTime.tryParse(json['period_end']?.toString() ?? '') ??
          DateTime.now(),
      grossTotal: _toDouble(json['gross_total']),
      totalDeductions: _toDouble(json['total_deductions']),
      netSettlement: _toDouble(json['net_settlement']),
      status: json['status']?.toString() ?? 'pending',
      receivedAt: json['received_at'] != null
          ? DateTime.tryParse(json['received_at'].toString())
          : null,
      notes: json['notes']?.toString(),
      items: items,
      orderCount: json['order_count'] is int
          ? json['order_count'] as int
          : int.tryParse(json['order_count']?.toString() ?? '0') ?? 0,
    );
  }
}

// ─── 미수금 요약 ─────────────────────────────

class UnsettledRevenueSummary {
  const UnsettledRevenueSummary({
    required this.revenue,
    required this.orderCount,
  });

  final double revenue;
  final int orderCount;
}

// ─── 유틸 ────────────────────────────────────

double _toDouble(dynamic value) {
  return switch (value) {
    num v => v.toDouble(),
    String v => double.tryParse(v) ?? 0,
    _ => 0,
  };
}

int _toInt(dynamic value) {
  return switch (value) {
    int v => v,
    num v => v.toInt(),
    String v => int.tryParse(v) ?? 0,
    _ => 0,
  };
}

Map<String, dynamic> _toJsonObject(dynamic value) {
  if (value is Map) {
    return Map<String, dynamic>.from(value);
  }

  if (value is String && value.trim().isNotEmpty) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is Map) {
        return Map<String, dynamic>.from(decoded);
      }
    } on FormatException {
      return const {};
    }
  }

  return const {};
}

double _roundMoney(double value) => (value * 100).round() / 100;
