import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../core/services/offline_mutation_queue_service.dart';
import '../../core/services/order_service.dart';
import '../../core/services/operational_day_service.dart';
import '../../core/utils/live_sync_scope.dart';
import '../../core/utils/coalesced_refresh.dart';
import '../../core/utils/read_epoch.dart';
import '../../core/utils/polling_utils.dart';
import '../../core/services/pos_backend.dart';
import 'order_model.dart';

class OrderState {
  const OrderState({
    this.cart = const [],
    this.isSubmitting = false,
    this.isSyncingOfflineQueue = false,
    this.offlineQueueCount = 0,
    this.error,
    this.activeOrder,
  });

  final List<CartItem> cart;
  final bool isSubmitting;
  final bool isSyncingOfflineQueue;
  final int offlineQueueCount;
  final String? error;
  final Order? activeOrder;

  OrderState copyWith({
    List<CartItem>? cart,
    bool? isSubmitting,
    bool? isSyncingOfflineQueue,
    int? offlineQueueCount,
    String? error,
    Order? activeOrder,
    bool clearError = false,
    bool clearActiveOrder = false,
  }) {
    return OrderState(
      cart: cart ?? this.cart,
      isSubmitting: isSubmitting ?? this.isSubmitting,
      isSyncingOfflineQueue:
          isSyncingOfflineQueue ?? this.isSyncingOfflineQueue,
      offlineQueueCount: offlineQueueCount ?? this.offlineQueueCount,
      error: clearError ? null : (error ?? this.error),
      activeOrder: clearActiveOrder ? null : (activeOrder ?? this.activeOrder),
    );
  }
}

class OrderNotifier extends StateNotifier<OrderState> {
  OrderNotifier({
    SupabaseClient? client,
    OperationalDayService? dayService,
    OrderService? orders,
  }) : _providedClient = client,
       _providedOrders = orders,
       _dayService = dayService ?? operationalDayService,
       super(const OrderState()) {
    _refreshOfflineQueueCount();
  }

  static const _fallbackPollInterval = Duration(seconds: 30);

  RealtimeChannel? _orderItemsChannel;
  String? _subscribedOrderId;
  String? _subscribedStoreId;
  String? _subscribedTableId;
  Timer? _pollTimer;
  Timer? _businessDayTimer;
  String? _businessDate;
  bool _realtimeConnected = false;
  final _uuid = const Uuid();
  int _commandGeneration = 0;
  final OrderService? _providedOrders;
  late final _orders = _providedOrders ?? OrderService(client: _client);
  final SupabaseClient? _providedClient;
  SupabaseClient get _client => _providedClient ?? supabase;
  final OperationalDayService _dayService;
  final _activeReads = ReadEpoch();
  final _activeRefresh = CoalescedRefresh();
  (String, String)? _requestedScope;

  List<Map<String, dynamic>> _cartPayloadItems() {
    return state.cart
        .map(
          (item) => {
            'menu_item_id': item.menuItemId,
            if (item.menuOptionKey != null)
              'menu_option_key': item.menuOptionKey,
            'label': item.name,
            'unit_price': item.price,
            'quantity': item.quantity,
            'item_type': 'menu',
            'is_takeout': item.isTakeout,
          },
        )
        .toList();
  }

  void addToCart(CartItem item) {
    final current = [...state.cart];
    final index = current.indexWhere(
      (cartItem) => cartItem.lineKey == item.lineKey,
    );

    if (index >= 0) {
      final existing = current[index];
      current[index] = existing.copyWith(
        quantity: existing.quantity + item.quantity,
      );
    } else {
      current.add(item);
    }

    state = state.copyWith(cart: current, clearError: true);
  }

  void replaceCartItem(CartItem original, CartItem replacement) {
    if (!state.cart.any((item) => item.lineKey == original.lineKey)) return;
    final current = state.cart
        .where((item) => item.lineKey != original.lineKey)
        .toList();
    final index = current.indexWhere(
      (item) => item.lineKey == replacement.lineKey,
    );
    if (index < 0) {
      current.add(replacement);
    } else {
      current[index] = current[index].copyWith(
        quantity: current[index].quantity + replacement.quantity,
      );
    }
    state = state.copyWith(cart: current, clearError: true);
  }

  void removeFromCart(CartItem target) {
    state = state.copyWith(
      cart: state.cart.where((item) => item.lineKey != target.lineKey).toList(),
      clearError: true,
    );
  }

  void decrementCartItem(CartItem target) {
    final current = [...state.cart];
    final index = current.indexWhere((item) => item.lineKey == target.lineKey);
    if (index < 0) {
      return;
    }

    final existing = current[index];
    if (existing.quantity <= 1) {
      current.removeAt(index);
    } else {
      current[index] = existing.copyWith(quantity: existing.quantity - 1);
    }

    state = state.copyWith(cart: current, clearError: true);
  }

  void setCartItemTakeout(CartItem target, bool isTakeout) {
    if (target.isTakeout == isTakeout) return;
    final current = [...state.cart];
    final sourceIndex = current.indexWhere(
      (item) => item.lineKey == target.lineKey,
    );
    if (sourceIndex < 0) return;

    final updated = current
        .removeAt(sourceIndex)
        .copyWith(isTakeout: isTakeout);
    final destinationIndex = current.indexWhere(
      (item) => item.lineKey == updated.lineKey,
    );
    if (destinationIndex >= 0) {
      final destination = current[destinationIndex];
      current[destinationIndex] = destination.copyWith(
        quantity: destination.quantity + updated.quantity,
      );
    } else {
      current.insert(
        sourceIndex > current.length ? current.length : sourceIndex,
        updated,
      );
    }
    state = state.copyWith(cart: current, clearError: true);
  }

  void clearCart() {
    state = state.copyWith(cart: const [], clearError: true);
  }

  void clearSession() {
    _commandGeneration++;
    _activeReads.invalidate();
    _requestedScope = null;
    _businessDayTimer?.cancel();
    _unsubscribeOrderItems();
    state = state.copyWith(
      cart: const [],
      clearActiveOrder: true,
      clearError: true,
      isSubmitting: false,
      isSyncingOfflineQueue: false,
      offlineQueueCount: 0,
    );
  }

  Future<void> _refreshOfflineQueueCount() async {
    final generation = _commandGeneration;
    final store = _requestedScope?.$1;
    try {
      final pending = store == null
          ? 0
          : (await _orders.commands.pending(store)).length;
      var legacy = 0;
      var legacyUnreadable = false;
      if (store != null) {
        try {
          legacy = (await offlineMutationQueueService.list())
              .where((r) => r.storeId == store)
              .length;
        } catch (_) {
          legacyUnreadable = true;
        }
      }
      if (mounted && generation == _commandGeneration) {
        state = state.copyWith(
          offlineQueueCount: pending + legacy,
          error: legacyUnreadable ? 'ORDER_RECOVERY_LEGACY_REVIEW' : null,
        );
      }
    } catch (_) {
      if (mounted && generation == _commandGeneration) {
        state = state.copyWith(error: 'ORDER_RECOVERY_STORAGE_UNAVAILABLE');
      }
    }
  }

  Future<void> loadActiveOrder(
    String tableId,
    String storeId, {
    bool syncOffline = true,
  }) {
    if (!mounted) return Future.value();
    final scope = (storeId, tableId);
    final changedScope = _requestedScope != scope;
    if (changedScope) _commandGeneration++;
    _requestedScope = scope;
    final token = _activeReads.begin(scope);
    if (changedScope) {
      _businessDayTimer?.cancel();
      unawaited(_unsubscribeOrderItems());
      state = state.copyWith(
        cart: const [],
        clearActiveOrder: true,
        isSubmitting: false,
        isSyncingOfflineQueue: false,
      );
    }
    return _activeRefresh.run(
      () => _loadActiveOrder(tableId, storeId, token, syncOffline: syncOffline),
    );
  }

  Future<void> _loadActiveOrder(
    String tableId,
    String storeId,
    ReadEpochToken token, {
    required bool syncOffline,
  }) async {
    if (!mounted || !_activeReads.accepts(token)) return;
    try {
      final operationalDay = await _dayService.ensureStoreDay(storeId);
      if (!mounted || !_activeReads.accepts(token)) return;
      if (operationalDay.enabled &&
          _businessDate != null &&
          _businessDate != operationalDay.window.dateKey) {
        state = state.copyWith(
          cart: const [],
          clearActiveOrder: true,
          isSubmitting: false,
          isSyncingOfflineQueue: false,
        );
      }
      _businessDate = operationalDay.window.dateKey;
      _businessDayTimer?.cancel();
      _businessDayTimer = Timer(
        operationalDay.window.refreshDelay(DateTime.now().toUtc()),
        () {
          if (mounted &&
              _subscribedStoreId == storeId &&
              _subscribedTableId == tableId) {
            unawaited(loadActiveOrder(tableId, storeId));
          }
        },
      );
      var query = _client
          .from('orders')
          .select(
            'id, table_id, status, created_at, guest_count, leftover_packaging_requests(status), order_items(id, menu_option_snapshot, created_at, menu_item_id, label, unit_price, quantity, status, is_takeout, item_type, combo_components, menu_items(name, name_ko, name_vi, name_en))',
          )
          .eq('table_id', tableId)
          .eq('restaurant_id', storeId)
          .not('status', 'in', '(completed,cancelled)');
      if (operationalDay.supportsClosure) {
        query = query.isFilter('operational_closed_at', null);
      }
      if (operationalDay.enabled) {
        query = query.or(
          'sales_channel.neq.dine_in,sales_channel.is.null,'
          'and(created_at.gte.${operationalDay.window.startIso8601},'
          'created_at.lt.${operationalDay.window.endIso8601})',
        );
      }
      final response = await query
          .order('created_at', ascending: false)
          .order('created_at', referencedTable: 'order_items', ascending: true)
          .order('id', referencedTable: 'order_items', ascending: true)
          .limit(1);
      if (!mounted || !_activeReads.accepts(token)) return;

      final activeOrder = response.isEmpty
          ? null
          : Order.fromJson(Map<String, dynamic>.from(response.first));

      state = state.copyWith(
        activeOrder: activeOrder,
        clearActiveOrder: activeOrder == null,
        clearError: true,
      );
      if (syncOffline) {
        unawaited(syncOfflineQueue(storeId, tableId: tableId));
      }

      await _subscribeOrderItems(activeOrder?.id, tableId, storeId, token);
    } catch (error) {
      if (!mounted || !_activeReads.accepts(token)) return;
      state = state.copyWith(error: 'Failed to load active order: $error');
    }
  }

  Future<void> _subscribeOrderItems(
    String? orderId,
    String tableId,
    String storeId,
    ReadEpochToken token,
  ) async {
    if (!mounted || !_activeReads.accepts(token)) return;
    if (_subscribedOrderId == orderId &&
        _subscribedTableId == tableId &&
        _subscribedStoreId == storeId &&
        _orderItemsChannel != null) {
      _ensureAutoRefresh(tableId, storeId);
      return;
    }

    await _unsubscribeOrderItems();
    if (!mounted || !_activeReads.accepts(token)) return;
    _subscribedOrderId = orderId;
    _subscribedTableId = tableId;
    _subscribedStoreId = storeId;
    _realtimeConnected = false;

    _orderItemsChannel = _client
        .channel(
          LiveSyncScope.entityChannel(
            'waiter_active_order',
            storeId,
            orderId ?? tableId,
          ),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'orders',
          filter: LiveSyncScope.storeFilter(storeId),
          callback: (payload) =>
              _refreshActiveOrderFromRealtime(tableId, storeId, payload),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'orders',
          filter: LiveSyncScope.storeFilter(storeId),
          callback: (payload) =>
              _refreshActiveOrderFromRealtime(tableId, storeId, payload),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'orders',
          filter: LiveSyncScope.storeFilter(storeId),
          callback: (payload) =>
              _refreshActiveOrderFromRealtime(tableId, storeId, payload),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'order_items',
          filter: LiveSyncScope.storeFilter(storeId),
          callback: (_) => _refreshActiveOrderFromRealtime(tableId, storeId),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'leftover_packaging_requests',
          filter: LiveSyncScope.storeFilter(storeId),
          callback: (_) => _refreshActiveOrderFromRealtime(tableId, storeId),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'leftover_packaging_requests',
          filter: LiveSyncScope.storeFilter(storeId),
          callback: (_) => _refreshActiveOrderFromRealtime(tableId, storeId),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'order_items',
          filter: LiveSyncScope.storeFilter(storeId),
          callback: (_) => _refreshActiveOrderFromRealtime(tableId, storeId),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'order_items',
          filter: LiveSyncScope.storeFilter(storeId),
          callback: (_) => _refreshActiveOrderFromRealtime(tableId, storeId),
        )
        .subscribe((status, [error]) {
          if (!mounted || _requestedScope != (storeId, tableId)) return;
          final connected = status == RealtimeSubscribeStatus.subscribed;
          if (connected != _realtimeConnected) {
            _realtimeConnected = connected;
            _ensureAutoRefresh(tableId, storeId);
          }
        });
    _ensureAutoRefresh(tableId, storeId);
  }

  Future<void> _unsubscribeOrderItems() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    final channel = _orderItemsChannel;
    _orderItemsChannel = null;
    _subscribedOrderId = null;
    _subscribedStoreId = null;
    _subscribedTableId = null;
    if (channel != null) await channel.unsubscribe();
  }

  void _refreshActiveOrderFromRealtime(
    String tableId,
    String storeId, [
    PostgresChangePayload? payload,
  ]) {
    if (!mounted || _requestedScope != (storeId, tableId)) {
      return;
    }
    if (payload != null && !_payloadBelongsToTable(payload, tableId)) {
      return;
    }
    unawaited(loadActiveOrder(tableId, storeId, syncOffline: false));
  }

  bool _payloadBelongsToTable(PostgresChangePayload payload, String tableId) {
    final newTableId = payload.newRecord['table_id']?.toString();
    final oldTableId = payload.oldRecord['table_id']?.toString();
    return newTableId == tableId || oldTableId == tableId;
  }

  void _ensureAutoRefresh(String tableId, String storeId) {
    if (_realtimeConnected) {
      _pollTimer?.cancel();
      _pollTimer = null;
      return;
    }

    if (_pollTimer != null &&
        _subscribedTableId == tableId &&
        _subscribedStoreId == storeId) {
      return;
    }

    _pollTimer?.cancel();
    _pollTimer = Timer(jitteredPollDelay(_fallbackPollInterval), () async {
      _pollTimer = null;
      if (mounted &&
          _subscribedTableId == tableId &&
          _subscribedStoreId == storeId) {
        await loadActiveOrder(tableId, storeId, syncOffline: false);
      }
      if (mounted &&
          !_realtimeConnected &&
          _subscribedTableId == tableId &&
          _subscribedStoreId == storeId) {
        _ensureAutoRefresh(tableId, storeId);
      }
    });
  }

  Future<void> submitOrder(String storeId, String tableId) async {
    if (state.isSubmitting) return;
    if (state.cart.isEmpty) {
      state = state.copyWith(error: _orderItemsRequiredMessage);
      return;
    }
    final generation = _commandGeneration;
    final actor = _client.auth.currentUser?.id;
    bool current() =>
        mounted &&
        generation == _commandGeneration &&
        _client.auth.currentUser?.id == actor;
    final items = _cartPayloadItems();
    state = state.copyWith(isSubmitting: true, clearError: true);
    try {
      await _orders.createOrder(
        storeId: storeId,
        tableId: tableId,
        items: items,
        clientMutationId: _uuid.v4(),
        isCurrent: current,
      );
      if (!current()) return;
      state = state.copyWith(cart: const []);
      await loadActiveOrder(tableId, storeId, syncOffline: false);
    } catch (error) {
      if (current()) {
        await _orderFailure(error, storeId, 'create', tableId, current);
      }
    } finally {
      if (current()) {
        await _refreshOfflineQueueCount();
        if (current()) state = state.copyWith(isSubmitting: false);
      }
    }
  }

  Future<void> addMoreItems(String orderId, String storeId) async {
    if (state.isSubmitting) return;
    if (state.cart.isEmpty) {
      state = state.copyWith(error: _orderItemsRequiredMessage);
      return;
    }
    final generation = _commandGeneration;
    final actor = _client.auth.currentUser?.id;
    bool current() =>
        mounted &&
        generation == _commandGeneration &&
        _client.auth.currentUser?.id == actor;
    final table = state.activeOrder?.tableId;
    final items = _cartPayloadItems();
    state = state.copyWith(isSubmitting: true, clearError: true);
    try {
      await _orders.addItemsToOrder(
        orderId: orderId,
        storeId: storeId,
        items: items,
        clientMutationId: _uuid.v4(),
        isCurrent: current,
      );
      if (!current()) return;
      state = state.copyWith(cart: const []);
      if (table != null) {
        await loadActiveOrder(table, storeId, syncOffline: false);
      }
    } catch (error) {
      if (current()) {
        await _orderFailure(error, storeId, 'add', orderId, current);
      }
    } finally {
      if (current()) {
        await _refreshOfflineQueueCount();
        if (current()) state = state.copyWith(isSubmitting: false);
      }
    }
  }

  Future<void> _orderFailure(
    Object error,
    String store,
    String kind,
    String target,
    bool Function() current,
  ) async {
    try {
      final pending = await _orders.commands.pending(store);
      if (!current()) return;
      if (pending.any((r) => r['kind'] == kind && r['target'] == target)) {
        state = state.copyWith(cart: const [], error: 'ORDER_RECOVERY_PENDING');
        return;
      }
    } catch (_) {
      /* The original storage error remains visible; no write is sent without an intent. */
    }
    if (current()) {
      state = state.copyWith(
        error: _mapOrderError(error, 'Failed to submit order'),
      );
    }
  }

  Future<bool> requestLeftoverPackaging(String orderId, String storeId) async {
    final tableId = state.activeOrder?.tableId;
    state = state.copyWith(isSubmitting: true, clearError: true);
    try {
      await orderService.requestLeftoverPackaging(
        orderId: orderId,
        storeId: storeId,
        requestId: _uuid.v4(),
      );
      if (tableId != null) {
        await loadActiveOrder(tableId, storeId, syncOffline: false);
      }
      return true;
    } catch (error) {
      state = state.copyWith(
        error: _mapOrderError(error, 'Failed to request leftover packaging'),
      );
      return false;
    } finally {
      state = state.copyWith(isSubmitting: false);
    }
  }

  Future<void> submitBuffetOrder(
    String storeId,
    String tableId,
    int guestCount,
  ) async {
    if (guestCount <= 0) {
      state = state.copyWith(error: 'Guest count must be at least 1.');
      return;
    }

    state = state.copyWith(isSubmitting: true, clearError: true);

    try {
      await orderService.createBuffetOrder(
        storeId: storeId,
        tableId: tableId,
        guestCount: guestCount,
        extraItems: _cartPayloadItems(),
      );

      state = state.copyWith(cart: const []);
      await loadActiveOrder(tableId, storeId);
    } catch (error) {
      state = state.copyWith(
        error: _mapOrderError(error, 'Failed to submit buffet order'),
      );
    } finally {
      state = state.copyWith(isSubmitting: false);
    }
  }

  Future<void> updateGuestCount(
    String orderId,
    String storeId,
    int guestCount,
  ) async {
    if (guestCount < 1) {
      state = state.copyWith(error: 'Guest count must be at least 1.');
      return;
    }

    final tableId = state.activeOrder?.tableId;
    state = state.copyWith(isSubmitting: true, clearError: true);

    try {
      await orderService.updateOrderGuestCount(
        orderId: orderId,
        storeId: storeId,
        guestCount: guestCount,
      );
      if (tableId != null) {
        await loadActiveOrder(tableId, storeId);
      }
    } catch (error) {
      state = state.copyWith(
        error: _mapOrderError(error, 'Failed to update guest count'),
      );
    } finally {
      state = state.copyWith(isSubmitting: false);
    }
  }

  Future<void> cancelOrder(String orderId, String storeId) async {
    state = state.copyWith(isSubmitting: true, clearError: true);
    try {
      await orderService.cancelOrder(orderId: orderId, storeId: storeId);
      state = state.copyWith(
        isSubmitting: false,
        clearActiveOrder: true,
        cart: const [],
        clearError: true,
      );
    } on PostgrestException catch (error) {
      state = state.copyWith(
        isSubmitting: false,
        error: _mapOrderError(error, 'Failed to cancel order'),
      );
    } catch (error) {
      state = state.copyWith(
        isSubmitting: false,
        error: _mapOrderError(error, 'Failed to cancel order'),
      );
    }
  }

  Future<bool> cancelOrderItem(String itemId, String storeId) async {
    final tableId = state.activeOrder?.tableId;
    state = state.copyWith(isSubmitting: true, clearError: true);
    try {
      await orderService.cancelOrderItem(itemId: itemId, storeId: storeId);
      if (tableId != null) {
        await loadActiveOrder(tableId, storeId);
      }
      return true;
    } catch (error) {
      state = state.copyWith(
        error: _mapOrderError(error, 'Failed to cancel item'),
      );
      return false;
    } finally {
      state = state.copyWith(isSubmitting: false);
    }
  }

  Future<bool> restoreCancelledOrder(
    String orderId,
    String storeId, {
    String? tableId,
  }) async {
    state = state.copyWith(isSubmitting: true, clearError: true);
    try {
      await orderService.restoreCancelledOrder(
        orderId: orderId,
        storeId: storeId,
      );
      if (tableId != null) {
        await loadActiveOrder(tableId, storeId);
      }
      return true;
    } catch (error) {
      state = state.copyWith(
        error: _mapOrderError(error, 'Failed to restore order'),
      );
      return false;
    } finally {
      state = state.copyWith(isSubmitting: false);
    }
  }

  Future<bool> restoreCancelledOrderItem(String itemId, String storeId) async {
    final tableId = state.activeOrder?.tableId;
    state = state.copyWith(isSubmitting: true, clearError: true);
    try {
      await orderService.restoreCancelledOrderItem(
        itemId: itemId,
        storeId: storeId,
      );
      if (tableId != null) {
        await loadActiveOrder(tableId, storeId);
      }
      return true;
    } catch (error) {
      state = state.copyWith(
        error: _mapOrderError(error, 'Failed to restore item'),
      );
      return false;
    } finally {
      state = state.copyWith(isSubmitting: false);
    }
  }

  Future<void> editOrderItemQuantity(
    String itemId,
    String storeId,
    int newQuantity,
  ) async {
    final tableId = state.activeOrder?.tableId;
    state = state.copyWith(isSubmitting: true, clearError: true);
    try {
      await orderService.editOrderItemQuantity(
        itemId: itemId,
        storeId: storeId,
        newQuantity: newQuantity,
      );
      if (tableId != null) {
        await loadActiveOrder(tableId, storeId);
      }
    } catch (error) {
      state = state.copyWith(
        error: _mapOrderError(error, 'Failed to change quantity'),
      );
    } finally {
      state = state.copyWith(isSubmitting: false);
    }
  }

  Future<void> transferOrderTable(
    String orderId,
    String storeId,
    String newTableId,
  ) async {
    state = state.copyWith(isSubmitting: true, clearError: true);
    try {
      await orderService.transferOrderTable(
        orderId: orderId,
        storeId: storeId,
        newTableId: newTableId,
      );
      await loadActiveOrder(newTableId, storeId);
    } catch (error) {
      state = state.copyWith(
        error: _mapOrderError(error, 'Failed to move table'),
      );
    } finally {
      state = state.copyWith(isSubmitting: false);
    }
  }

  Future<void> updateOrderItemStatus(
    String itemId,
    String newStatus,
    String storeId,
    String tableId,
  ) async {
    if (itemId.isEmpty) {
      return;
    }

    final previousOrder = state.activeOrder;
    if (previousOrder != null) {
      final updatedItems = previousOrder.items.map((item) {
        if (item.id != itemId) {
          return item;
        }
        return item.copyWith(status: newStatus);
      }).toList();
      state = state.copyWith(
        activeOrder: previousOrder.copyWith(items: updatedItems),
        clearError: true,
      );
    }

    try {
      await orderService.updateOrderItemStatus(
        itemId: itemId,
        storeId: storeId,
        status: newStatus,
      );
      await loadActiveOrder(tableId, storeId);
    } on PostgrestException catch (error) {
      state = state.copyWith(
        activeOrder: previousOrder,
        error: _mapOrderError(error, 'Failed to update item status'),
      );
    } catch (error) {
      state = state.copyWith(
        activeOrder: previousOrder,
        error: _mapOrderError(error, 'Failed to update item status'),
      );
    }
  }

  Future<void> syncOfflineQueue(String storeId, {String? tableId}) async {
    if (!mounted || state.isSyncingOfflineQueue) return;
    final generation = _commandGeneration;
    final actor = _client.auth.currentUser?.id;
    bool current() =>
        mounted &&
        generation == _commandGeneration &&
        _client.auth.currentUser?.id == actor;
    state = state.copyWith(isSyncingOfflineQueue: true, clearError: true);
    try {
      // Legacy records have no verifiable original actor/project. Preserve them
      // for review; never silently assign them to whoever logs in next.
      var legacy = false;
      try {
        legacy = (await offlineMutationQueueService.list())
            .where((r) => r.storeId == storeId)
            .isNotEmpty;
      } catch (_) {
        legacy = true;
      }
      await _orders.commands.recover(storeId, isCurrent: current);
      if (current() && legacy) {
        state = state.copyWith(error: 'ORDER_RECOVERY_LEGACY_REVIEW');
      }
    } catch (error) {
      if (current()) {
        state = state.copyWith(error: _mapOrderError(error, 'Sync failed'));
      }
    } finally {
      if (current()) {
        await _refreshOfflineQueueCount();
        if (current()) state = state.copyWith(isSyncingOfflineQueue: false);
      }
    }
    if (tableId != null && current()) {
      await loadActiveOrder(tableId, storeId, syncOffline: false);
    }
  }

  @override
  void dispose() {
    _commandGeneration++;
    _activeReads.dispose();
    _activeRefresh.dispose();
    _businessDayTimer?.cancel();
    _pollTimer?.cancel();
    unawaited(_unsubscribeOrderItems());
    super.dispose();
  }
}

final orderProvider = StateNotifierProvider<OrderNotifier, OrderState>(
  (ref) => OrderNotifier(),
);

const _orderItemsRequiredMessage =
    'Add at least one item before sending the order.';

String _mapOrderError(Object error, String fallbackPrefix) {
  if (error is PostgrestException) {
    return switch (error.message) {
      'RESTAURANT_KITCHEN_CLOSED' => 'RESTAURANT_KITCHEN_CLOSED',
      'RESTAURANT_DAILY_SALES_CLOSED' => 'RESTAURANT_DAILY_SALES_CLOSED',
      'ORDER_BUSINESS_DAY_EXPIRED' ||
      'ORDER_OPERATIONS_CLOSED' => 'ORDER_BUSINESS_DAY_EXPIRED',
      'TABLE_ALREADY_OCCUPIED' => 'The selected table is already occupied.',
      'TABLE_NOT_AVAILABLE' => 'The selected table is not available.',
      'TABLE_NOT_FOUND' => 'The selected table could not be found.',
      'ORDER_ITEMS_REQUIRED' =>
        'Add at least one item before sending the order.',
      'INVALID_ORDER_ITEM_INPUT' =>
        'One or more selected items are invalid for this order.',
      'MENU_ITEM_PRICE_INVALID' =>
        'The menu options or price changed. Refresh the menu and select the items again.',
      'MENU_ITEM_NOT_AVAILABLE' =>
        'One or more selected menu items are unavailable.',
      'ORDER_CREATE_FORBIDDEN' =>
        'You do not have permission to create an order for this restaurant.',
      'ORDER_MUTATION_FORBIDDEN' =>
        'You do not have permission to change this order.',
      'ORDER_NOT_FOUND' => 'The selected order could not be found.',
      'ORDER_NOT_MUTABLE' => 'This order can no longer be changed.',
      'ORDER_NON_REVENUE_PAYMENT_STARTED' =>
        'Service checkout has started. Additional items cannot be added.',
      'ORDER_NOT_CANCELLABLE' =>
        'Only pending or confirmed orders can be cancelled.',
      'BUFFET_GUEST_COUNT_REQUIRED' =>
        'Buffet orders require a guest count of at least 1.',
      'OPERATION_MODE_MISMATCH' =>
        'This restaurant does not support buffet ordering for this flow.',
      'ORDER_ITEM_STATUS_FORBIDDEN' =>
        'You do not have permission to change kitchen item status.',
      'ORDER_ITEM_NOT_FOUND' => 'The selected order item could not be found.',
      'INVALID_ORDER_ITEM_STATUS_TRANSITION' =>
        'That item status transition is not allowed.',
      'ORDER_NOT_PAYABLE' => 'Completed or cancelled orders cannot be changed.',
      'ITEM_NOT_CANCELLABLE' =>
        'Only pending or preparing items can be cancelled.',
      'ITEM_NOT_EDITABLE' =>
        'Only pending items can have their quantity edited.',
      'ITEM_IS_CANCELLED' => 'This item has been cancelled.',
      'ORDER_NOT_CANCELLED' => 'This order is no longer cancelled.',
      'ITEM_NOT_CANCELLED' => 'This item is no longer cancelled.',
      'CANCELLATION_NOT_FOUND' => 'The cancellation can no longer be restored.',
      'INVALID_QUANTITY' => 'Quantity must be at least 1.',
      'TRANSFER_SAME_TABLE' => 'Cannot transfer to the same table.',
      _ => '$fallbackPrefix: ${error.message}',
    };
  }
  return '$fallbackPrefix: $error';
}
