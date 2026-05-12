import '../../main.dart';
import 'rpc_compat.dart';

Map<String, dynamic> normalizeInventoryItemPatch(Map<String, dynamic> data) {
  final patch = <String, dynamic>{};

  if (data.containsKey('name')) {
    patch['name'] = data['name'];
  }
  if (data.containsKey('unit')) {
    patch['unit'] = data['unit'];
  }
  if (data.containsKey('current_stock') && data['current_stock'] != null) {
    patch['current_stock'] = data['current_stock'];
  }
  if (data.containsKey('reorder_point')) {
    patch['reorder_point'] = data['reorder_point'];
  }
  if (data.containsKey('cost_per_unit')) {
    patch['cost_per_unit'] = data['cost_per_unit'];
  }
  if (data.containsKey('supplier_name')) {
    final supplierName = data['supplier_name'];
    patch['supplier_name'] =
        supplierName is String && supplierName.trim().isEmpty
        ? null
        : supplierName;
  }

  return patch;
}

class InventoryService {
  Future<List<Map<String, dynamic>>> fetchIngredients(String storeId) =>
      _rpcList(
        'get_inventory_ingredient_catalog',
        params: {'p_store_id': storeId},
      );

  Future<void> createIngredient({
    required String storeId,
    required String name,
    required String unit,
    double? currentStock,
    double? reorderPoint,
    double? costPerUnit,
    String? supplierName,
  }) async {
    await supabase.rpc(
      'create_inventory_item',
      params: {
        'p_store_id': storeId,
        'p_name': name,
        'p_unit': unit,
        'p_current_stock': currentStock,
        'p_reorder_point': reorderPoint,
        'p_cost_per_unit': costPerUnit,
        'p_supplier_name': supplierName,
      },
    );
  }

  Future<void> updateIngredient(
    String id,
    Map<String, dynamic> data, {
    required String storeId,
  }) async {
    await supabase.rpc(
      'update_inventory_item',
      params: {
        'p_item_id': id,
        'p_store_id': storeId,
        'p_patch': normalizeInventoryItemPatch(data),
      },
    );
  }

  Future<void> deleteIngredient(String id, {required String storeId}) async {
    await supabase.rpc(
      'delete_inventory_item',
      params: {'p_store_id': storeId, 'p_item_id': id},
    );
  }

  Future<void> restockIngredient({
    required String storeId,
    required String ingredientId,
    required double quantityG,
    String? note,
  }) async {
    await supabase.rpc(
      'restock_inventory_item',
      params: {
        'p_store_id': storeId,
        'p_ingredient_id': ingredientId,
        'p_quantity_g': quantityG,
        'p_note': note,
      },
    );
  }

  Future<void> recordWaste({
    required String storeId,
    required String ingredientId,
    required double quantityG,
    String? note,
  }) async {
    await supabase.rpc(
      'record_inventory_waste',
      params: {
        'p_store_id': storeId,
        'p_ingredient_id': ingredientId,
        'p_quantity_g': quantityG,
        'p_note': note,
      },
    );
  }

  Future<List<Map<String, dynamic>>> fetchMenuItems(String storeId) =>
      _selectStoreScoped(
        table: 'menu_items',
        storeId: storeId,
        columns: 'id, name, sort_order',
        orderBy: 'sort_order',
      );

  Future<List<Map<String, dynamic>>> fetchAllRecipes(String storeId) =>
      _rpcListWithStoreCompat(
        'get_inventory_recipe_catalog',
        params: {'p_store_id': storeId, 'p_menu_item_id': null},
      );

  Future<List<Map<String, dynamic>>> fetchRecipesForMenu(
    String storeId,
    String menuItemId,
  ) => _rpcListWithStoreCompat(
    'get_inventory_recipe_catalog',
    params: {'p_store_id': storeId, 'p_menu_item_id': menuItemId},
  );

  Future<void> upsertRecipe({
    required String storeId,
    required String menuItemId,
    required String ingredientId,
    required double quantityG,
  }) async {
    await supabase.rpc(
      'upsert_inventory_recipe_line',
      params: {
        'p_store_id': storeId,
        'p_menu_item_id': menuItemId,
        'p_ingredient_id': ingredientId,
        'p_quantity_g': quantityG,
      },
    );
  }

  Future<void> deleteRecipe(
    String menuItemId,
    String ingredientId, {
    required String storeId,
  }) async {
    await supabase.rpc(
      'delete_inventory_recipe_line_by_keys',
      params: {
        'p_store_id': storeId,
        'p_menu_item_id': menuItemId,
        'p_ingredient_id': ingredientId,
      },
    );
  }

  Future<List<Map<String, dynamic>>> fetchPhysicalCounts(
    String storeId,
    String countDate,
  ) => _rpcList(
    'get_inventory_physical_count_sheet',
    params: {'p_store_id': storeId, 'p_count_date': countDate},
  );

  Future<void> submitPhysicalCount({
    required String storeId,
    required String ingredientId,
    required String countDate,
    required double actualQty,
    String? note,
  }) async {
    await supabase.rpc(
      'apply_inventory_physical_count_line',
      params: {
        'p_store_id': storeId,
        'p_count_date': countDate,
        'p_ingredient_id': ingredientId,
        'p_actual_quantity_g': actualQty,
        'p_note': note,
      },
    );
  }

  Future<List<Map<String, dynamic>>> fetchTransactions({
    required String storeId,
    required DateTime from,
    required DateTime to,
  }) => _rpcList(
    'get_inventory_transaction_visibility',
    params: {
      'p_store_id': storeId,
      'p_from': from.toUtc().toIso8601String(),
      'p_to': to.toUtc().toIso8601String(),
    },
  );

  Future<Map<String, dynamic>> fetchInventoryPurchaseDashboard({
    required String storeId,
  }) async {
    final result = await supabase.rpc(
      'get_inventory_purchase_dashboard',
      params: {'p_store_id': storeId, 'p_brand_id': null},
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<String> runInventoryPurchaseRecommendation({
    required String storeId,
    required double targetStockDays,
    required DateTime asOfDate,
  }) async {
    final result = await supabase.rpc(
      'run_inventory_purchase_recommendation',
      params: {
        'p_store_id': storeId,
        'p_target_stock_days': targetStockDays,
        'p_as_of_date': asOfDate.toIso8601String().split('T').first,
      },
    );
    return result.toString();
  }

  Future<Map<String, dynamic>?> fetchLatestInventoryPurchaseRecommendationRun({
    required String storeId,
  }) async {
    final result = await supabase
        .from('inventory_recommendation_runs')
        .select('id, restaurant_id, run_date, target_stock_days, created_at')
        .eq('restaurant_id', storeId)
        .order('created_at', ascending: false)
        .limit(1)
        .maybeSingle();

    if (result == null) {
      return null;
    }
    return Map<String, dynamic>.from(result);
  }

  Future<List<Map<String, dynamic>>> fetchInventoryPurchaseRecommendationLines({
    required String runId,
  }) async {
    final result = await supabase
        .from('inventory_recommendation_lines')
        .select(
          'id, product_id, supplier_id, current_stock_base, avg_daily_consumption_base, target_stock_days, recommended_quantity_base, recommended_order_units, estimated_days_remaining, risk_status, created_at, product:inventory_products(name), supplier:inventory_suppliers(name)',
        )
        .eq('run_id', runId)
        .order('recommended_order_units', ascending: false)
        .limit(8);

    return List<Map<String, dynamic>>.from(result as List);
  }

  Future<List<Map<String, dynamic>>> createPurchaseOrdersFromRecommendation({
    required String runId,
    DateTime? requestedDeliveryDate,
  }) async {
    final result = await supabase.rpc(
      'create_purchase_orders_from_recommendation',
      params: {
        'p_run_id': runId,
        'p_requested_delivery_date': requestedDeliveryDate
            ?.toIso8601String()
            .split('T')
            .first,
      },
    );

    return List<Map<String, dynamic>>.from(result as List);
  }

  Future<List<Map<String, dynamic>>> fetchRecentInventoryPurchaseOrders({
    required String storeId,
  }) async {
    final orders = await supabase
        .from('inventory_purchase_orders')
        .select(
          'id, purchase_order_no, status, requested_delivery_date, total_amount, total_supply_amount, tax_amount, created_at, supplier:inventory_suppliers(name)',
        )
        .eq('restaurant_id', storeId)
        .order('created_at', ascending: false)
        .limit(6);

    final orderList = List<Map<String, dynamic>>.from(orders as List);
    if (orderList.isEmpty) {
      return orderList;
    }

    final orderIds = orderList.map((order) => order['id']).toList();
    final lines = await supabase
        .from('inventory_purchase_order_lines')
        .select('purchase_order_id')
        .inFilter('purchase_order_id', orderIds);

    final counts = <String, int>{};
    for (final row in List<Map<String, dynamic>>.from(lines as List)) {
      final orderId = row['purchase_order_id']?.toString();
      if (orderId == null) continue;
      counts[orderId] = (counts[orderId] ?? 0) + 1;
    }

    return orderList.map((order) {
      final copy = Map<String, dynamic>.from(order);
      copy['line_count'] = counts[order['id']?.toString() ?? ''] ?? 0;
      return copy;
    }).toList();
  }

  Future<Map<String, dynamic>?> fetchInventoryPurchaseOrderDetail({
    required String purchaseOrderId,
  }) async {
    final order = await supabase
        .from('inventory_purchase_orders')
        .select(
          'id, purchase_order_no, status, requested_delivery_date, total_amount, total_supply_amount, tax_amount, memo, created_at, supplier:inventory_suppliers(name)',
        )
        .eq('id', purchaseOrderId)
        .maybeSingle();

    if (order == null) {
      return null;
    }

    final lines = await supabase
        .from('inventory_purchase_order_lines')
        .select(
          'id, product_id, supplier_item_id, recommended_quantity_base, ordered_quantity_base, ordered_quantity_unit, order_unit, unit_price, supply_amount, tax_amount, memo, recommendation_snapshot, product:inventory_products(name), supplier_item:inventory_supplier_items(supplier_sku, order_unit_quantity_base, min_order_quantity)',
        )
        .eq('purchase_order_id', purchaseOrderId)
        .order('supply_amount', ascending: false);

    final receipts = await supabase
        .from('inventory_receipts')
        .select('id, status, received_at, created_at, memo')
        .eq('purchase_order_id', purchaseOrderId)
        .order('received_at', ascending: false);

    final receiptList = List<Map<String, dynamic>>.from(receipts as List);
    final receiptIds = receiptList.map((receipt) => receipt['id']).toList();
    final receiptLines = receiptIds.isEmpty
        ? <Map<String, dynamic>>[]
        : List<Map<String, dynamic>>.from(
            await supabase
                    .from('inventory_receipt_lines')
                    .select(
                      'receipt_id, purchase_order_line_id, received_quantity_base, accepted_quantity_base, rejected_quantity_base, memo',
                    )
                    .inFilter('receipt_id', receiptIds)
                as List,
          );

    final receiptStatusById = <String, String>{};
    var confirmedReceiptCount = 0;
    var draftReceiptCount = 0;
    var cancelledReceiptCount = 0;
    final receiptLineCountById = <String, int>{};
    final receiptReceivedById = <String, double>{};
    final receiptAcceptedById = <String, double>{};
    final receiptRejectedById = <String, double>{};
    for (final receipt in receiptList) {
      final receiptId = receipt['id']?.toString();
      final status = receipt['status']?.toString() ?? 'draft';
      if (receiptId != null) {
        receiptStatusById[receiptId] = status;
      }
      switch (status) {
        case 'confirmed':
          confirmedReceiptCount += 1;
          break;
        case 'cancelled':
          cancelledReceiptCount += 1;
          break;
        default:
          draftReceiptCount += 1;
      }
    }

    final receivedByLine = <String, double>{};
    final acceptedByLine = <String, double>{};
    final rejectedByLine = <String, double>{};
    for (final receiptLine in receiptLines) {
      final lineId = receiptLine['purchase_order_line_id']?.toString();
      final receiptId = receiptLine['receipt_id']?.toString();
      if (lineId == null || receiptId == null) continue;

      receiptLineCountById[receiptId] =
          (receiptLineCountById[receiptId] ?? 0) + 1;
      receiptReceivedById[receiptId] =
          (receiptReceivedById[receiptId] ?? 0) +
          ((receiptLine['received_quantity_base'] as num?)?.toDouble() ?? 0);
      receiptAcceptedById[receiptId] =
          (receiptAcceptedById[receiptId] ?? 0) +
          ((receiptLine['accepted_quantity_base'] as num?)?.toDouble() ?? 0);
      receiptRejectedById[receiptId] =
          (receiptRejectedById[receiptId] ?? 0) +
          ((receiptLine['rejected_quantity_base'] as num?)?.toDouble() ?? 0);

      final status = receiptStatusById[receiptId] ?? 'draft';
      if (status != 'confirmed') continue;

      receivedByLine[lineId] =
          (receivedByLine[lineId] ?? 0) +
          ((receiptLine['received_quantity_base'] as num?)?.toDouble() ?? 0);
      acceptedByLine[lineId] =
          (acceptedByLine[lineId] ?? 0) +
          ((receiptLine['accepted_quantity_base'] as num?)?.toDouble() ?? 0);
      rejectedByLine[lineId] =
          (rejectedByLine[lineId] ?? 0) +
          ((receiptLine['rejected_quantity_base'] as num?)?.toDouble() ?? 0);
    }

    var totalExpectedBase = 0.0;
    var totalReceivedBase = 0.0;
    var totalAcceptedBase = 0.0;
    var totalRejectedBase = 0.0;
    final lineList = List<Map<String, dynamic>>.from(lines as List).map((line) {
      final copy = Map<String, dynamic>.from(line);
      final lineId = copy['id']?.toString() ?? '';
      final orderedBase =
          (copy['ordered_quantity_base'] as num?)?.toDouble() ?? 0;
      final receivedBase = receivedByLine[lineId] ?? 0;
      final acceptedBase = acceptedByLine[lineId] ?? 0;
      final rejectedBase = rejectedByLine[lineId] ?? 0;
      final remainingBase = orderedBase - acceptedBase;

      totalExpectedBase += orderedBase;
      totalReceivedBase += receivedBase;
      totalAcceptedBase += acceptedBase;
      totalRejectedBase += rejectedBase;

      copy['received_quantity_base'] = receivedBase;
      copy['accepted_quantity_base'] = acceptedBase;
      copy['rejected_quantity_base'] = rejectedBase;
      copy['remaining_quantity_base'] = remainingBase > 0 ? remainingBase : 0;
      copy['receipt_visibility_status'] =
          acceptedBase >= orderedBase && orderedBase > 0
          ? 'received'
          : acceptedBase > 0
          ? 'partially_received'
          : 'pending';
      return copy;
    }).toList();

    final latestReceipt = receiptList.isEmpty ? null : receiptList.first;
    final orderCopy = Map<String, dynamic>.from(order);
    orderCopy['confirmed_receipt_count'] = confirmedReceiptCount;
    orderCopy['draft_receipt_count'] = draftReceiptCount;
    orderCopy['cancelled_receipt_count'] = cancelledReceiptCount;
    orderCopy['total_expected_quantity_base'] = totalExpectedBase;
    orderCopy['total_received_quantity_base'] = totalReceivedBase;
    orderCopy['total_accepted_quantity_base'] = totalAcceptedBase;
    orderCopy['total_rejected_quantity_base'] = totalRejectedBase;
    orderCopy['total_remaining_quantity_base'] =
        totalExpectedBase - totalAcceptedBase > 0
        ? totalExpectedBase - totalAcceptedBase
        : 0;
    orderCopy['latest_receipt_status'] = latestReceipt?['status'];
    orderCopy['latest_receipt_at'] =
        latestReceipt?['received_at'] ?? latestReceipt?['created_at'];

    final enrichedReceipts = receiptList.map((receipt) {
      final copy = Map<String, dynamic>.from(receipt);
      final receiptId = copy['id']?.toString() ?? '';
      copy['line_count'] = receiptLineCountById[receiptId] ?? 0;
      copy['received_quantity_base'] = receiptReceivedById[receiptId] ?? 0;
      copy['accepted_quantity_base'] = receiptAcceptedById[receiptId] ?? 0;
      copy['rejected_quantity_base'] = receiptRejectedById[receiptId] ?? 0;
      return copy;
    }).toList();

    return {
      'order': orderCopy,
      'lines': lineList,
      'receipts': enrichedReceipts,
    };
  }

  Future<List<Map<String, dynamic>>> _rpcList(
    String functionName, {
    required Map<String, dynamic> params,
  }) async {
    final result = await supabase.rpc(functionName, params: params);
    return List<Map<String, dynamic>>.from(result as List);
  }

  Future<List<Map<String, dynamic>>> _rpcListWithStoreCompat(
    String functionName, {
    required Map<String, dynamic> params,
  }) async {
    final result = await runRpcWithStoreCompat<dynamic>(
      fnName: functionName,
      params: params,
      invoke: (nextParams) => supabase.rpc(functionName, params: nextParams),
    );
    return List<Map<String, dynamic>>.from(result as List);
  }

  Future<List<Map<String, dynamic>>> _selectStoreScoped({
    required String table,
    required String storeId,
    required String columns,
    String? orderBy,
  }) async {
    dynamic query = supabase
        .from(table)
        .select(columns)
        .eq('restaurant_id', storeId);
    if (orderBy != null) {
      query = query.order(orderBy);
    }
    final result = await query;
    return List<Map<String, dynamic>>.from(result as List);
  }
}

final inventoryService = InventoryService();
