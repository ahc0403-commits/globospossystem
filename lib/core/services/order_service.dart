import 'pos_backend.dart';
import 'operational_day_service.dart';
import '../utils/time_utils.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../orders/recoverable_order_commands.dart';
import '../orders/order_intent_journal.dart';

class OrderService {
  OrderService({SupabaseClient? client, OrderIntentJournal? journal})
    : _providedClient = client,
      _providedJournal = journal;
  final SupabaseClient? _providedClient;
  final OrderIntentJournal? _providedJournal;
  RecoverableOrderCommands? _commands;
  RecoverableOrderCommands get commands => _commands ??=
      RecoverableOrderCommands(_client, journal: _providedJournal);
  SupabaseClient get _client => _providedClient ?? supabase;

  Future<Map<String, dynamic>> createOrder({
    required String storeId,
    required String tableId,
    required List<Map<String, dynamic>> items,
    String? clientMutationId,
    String? businessDate,
    bool Function()? isCurrent,
  }) async {
    if (clientMutationId != null) {
      final result = await commands.execute(
        kind: 'create',
        store: storeId,
        target: tableId,
        operation: clientMutationId,
        isCurrent: isCurrent,
        params: {
          'p_store_id': storeId,
          'p_table_id': tableId,
          'p_items': items,
          'p_business_date':
              businessDate ?? TimeUtils.currentVietnamBusinessDay().dateKey,
        },
      );
      return Map<String, dynamic>.from(result as Map);
    }

    final result = await supabase.rpc(
      'create_order',
      params: {'p_store_id': storeId, 'p_table_id': tableId, 'p_items': items},
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<Map<String, dynamic>> createBuffetOrder({
    required String storeId,
    required String tableId,
    required int guestCount,
    List<Map<String, dynamic>> extraItems = const [],
  }) async {
    final result = await supabase.rpc(
      'create_buffet_order',
      params: {
        'p_store_id': storeId,
        'p_table_id': tableId,
        'p_guest_count': guestCount,
        'p_extra_items': extraItems,
      },
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<Map<String, dynamic>> createStaffMealOrder({
    required String storeId,
    required List<Map<String, dynamic>> items,
    String? staffUserId,
    String? reason,
    required String managerPin,
  }) async {
    final result = await supabase.rpc(
      'create_staff_meal_order',
      params: {
        'p_store_id': storeId,
        'p_items': items,
        'p_staff_user_id': staffUserId,
        'p_reason': reason,
        'p_manager_pin': managerPin,
      },
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<Map<String, dynamic>> updateOrderGuestCount({
    required String orderId,
    required String storeId,
    required int guestCount,
  }) async {
    final result = await supabase.rpc(
      'update_order_guest_count',
      params: {
        'p_order_id': orderId,
        'p_store_id': storeId,
        'p_guest_count': guestCount,
      },
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<List<Map<String, dynamic>>> addItemsToOrder({
    required String orderId,
    required String storeId,
    required List<Map<String, dynamic>> items,
    String? clientMutationId,
    bool Function()? isCurrent,
  }) async {
    if (clientMutationId != null) {
      final result = await commands.execute(
        kind: 'add',
        store: storeId,
        target: orderId,
        operation: clientMutationId,
        isCurrent: isCurrent,
        params: {
          'p_order_id': orderId,
          'p_store_id': storeId,
          'p_items': items,
        },
      );
      return (result as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    }

    final result = await supabase.rpc(
      'add_items_to_order',
      params: {'p_order_id': orderId, 'p_store_id': storeId, 'p_items': items},
    );
    return (result as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  Future<void> updateOrderItemStatus({
    required String itemId,
    required String storeId,
    required String status,
  }) async {
    await supabase.rpc(
      'update_order_item_status',
      params: {
        'p_item_id': itemId,
        'p_store_id': storeId,
        'p_new_status': status,
      },
    );
  }

  Future<void> completeKitchenOrder({
    required String orderId,
    required String storeId,
  }) async {
    await supabase.rpc(
      'complete_kitchen_order',
      params: {'p_order_id': orderId, 'p_store_id': storeId},
    );
  }

  Future<Map<String, dynamic>> cancelOrder({
    required String orderId,
    required String storeId,
  }) async {
    final result = await supabase.rpc(
      'cancel_order',
      params: {'p_order_id': orderId, 'p_store_id': storeId},
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<void> cancelCurrentTableOrder({
    required String storeId,
    required String tableId,
    required String reason,
  }) async {
    await supabase.rpc(
      'cancel_current_table_order',
      params: {
        'p_store_id': storeId,
        'p_table_id': tableId,
        'p_reason': reason,
      },
    );
    operationalDayService.invalidate(storeId);
  }

  Future<Map<String, dynamic>> requestLeftoverPackaging({
    required String orderId,
    required String storeId,
    required String requestId,
  }) async {
    final result = await supabase.rpc(
      'request_leftover_packaging',
      params: {
        'p_order_id': orderId,
        'p_store_id': storeId,
        'p_request_id': requestId,
      },
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<void> cancelOrderItem({
    required String itemId,
    required String storeId,
  }) async {
    await supabase.rpc(
      'cancel_order_item',
      params: {'p_item_id': itemId, 'p_store_id': storeId},
    );
  }

  Future<Map<String, dynamic>> restoreCancelledOrder({
    required String orderId,
    required String storeId,
  }) async {
    final result = await supabase.rpc(
      'restore_cancelled_order',
      params: {'p_order_id': orderId, 'p_store_id': storeId},
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<void> restoreCancelledOrderItem({
    required String itemId,
    required String storeId,
  }) async {
    await supabase.rpc(
      'restore_cancelled_order_item',
      params: {'p_item_id': itemId, 'p_store_id': storeId},
    );
  }

  Future<Map<String, dynamic>> cancelItemQuantity({
    required String storeId,
    required String itemId,
    required int expectedQuantity,
    required int newQuantity,
    required String operationId,
  }) async => Map<String, dynamic>.from(
    await supabase.rpc(
          'cashier_cancel_item_quantity',
          params: {
            'p_store_id': storeId,
            'p_item_id': itemId,
            'p_expected_quantity': expectedQuantity,
            'p_new_quantity': newQuantity,
            'p_operation_id': operationId,
            'p_reason': 'customer_request',
          },
        )
        as Map,
  );
  Future<void> restoreItemQuantity({
    required String storeId,
    required String operationId,
  }) async {
    await supabase.rpc(
      'cashier_restore_item_quantity',
      params: {'p_store_id': storeId, 'p_operation_id': operationId},
    );
  }

  Future<Map<String, dynamic>> moveOrderItems({
    required String storeId,
    required String orderId,
    required String targetTableId,
    required List<Map<String, dynamic>> items,
    required String operationId,
  }) async => Map<String, dynamic>.from(
    await supabase.rpc(
          'cashier_move_order_items',
          params: {
            'p_store_id': storeId,
            'p_source_order_id': orderId,
            'p_target_table_id': targetTableId,
            'p_items': items,
            'p_operation_id': operationId,
          },
        )
        as Map,
  );

  Future<void> editOrderItemQuantity({
    required String itemId,
    required String storeId,
    required int newQuantity,
  }) async {
    await supabase.rpc(
      'edit_order_item_quantity',
      params: {
        'p_item_id': itemId,
        'p_store_id': storeId,
        'p_new_quantity': newQuantity,
      },
    );
  }

  Future<Map<String, dynamic>> transferOrderTable({
    required String orderId,
    required String storeId,
    required String newTableId,
  }) async {
    final result = await supabase.rpc(
      'transfer_order_table',
      params: {
        'p_order_id': orderId,
        'p_store_id': storeId,
        'p_new_table_id': newTableId,
      },
    );
    return Map<String, dynamic>.from(result as Map);
  }
}

final orderService = OrderService();
