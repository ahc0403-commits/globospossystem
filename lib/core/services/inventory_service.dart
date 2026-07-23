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
  Future<Map<String, dynamic>> recordEmployeeInventoryAdjustment({
    required String storeId,
    required String employeeNumber,
    required String ingredientId,
    required String transactionType,
    required double quantityG,
    String? note,
  }) async {
    final response = await supabase.rpc(
      'record_employee_inventory_adjustment',
      params: {
        'p_store_id': storeId,
        'p_employee_number': employeeNumber.trim().toUpperCase(),
        'p_ingredient_id': ingredientId,
        'p_transaction_type': transactionType,
        'p_quantity_g': quantityG,
        'p_note': note,
      },
    );
    return Map<String, dynamic>.from(response as Map);
  }

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

  Future<List<Map<String, dynamic>>> fetchMenuCategories(String storeId) =>
      _selectStoreScoped(
        table: 'menu_categories',
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

  Future<Map<String, dynamic>> createInventoryMenuWithRecipe({
    required String storeId,
    String? categoryId,
    required String name,
    required double price,
    String? description,
    required List<Map<String, dynamic>> recipeLines,
  }) async {
    final result = await supabase.rpc(
      'create_inventory_menu_with_recipe',
      params: {
        'p_store_id': storeId,
        'p_category_id': categoryId,
        'p_name': name,
        'p_price': price,
        'p_description': description,
        'p_recipe_lines': recipeLines,
      },
    );
    return Map<String, dynamic>.from(result as Map);
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

  Future<List<Map<String, dynamic>>> fetchInventoryStockStatus({
    required String storeId,
    DateTime? asOfDate,
  }) => _rpcList(
    'get_inventory_stock_status',
    params: {
      'p_store_id': storeId,
      'p_as_of_date': (asOfDate ?? DateTime.now())
          .toIso8601String()
          .split('T')
          .first,
    },
  );

  Future<List<Map<String, dynamic>>> fetchInventoryCostAnalysis({
    required String storeId,
    DateTime? from,
    DateTime? to,
  }) => _rpcList(
    'get_inventory_cost_analysis',
    params: {
      'p_store_id': storeId,
      'p_from': (from ?? DateTime.now().subtract(const Duration(days: 6)))
          .toIso8601String()
          .split('T')
          .first,
      'p_to': (to ?? DateTime.now()).toIso8601String().split('T').first,
    },
  );

  Future<int> refreshInventoryDailyConsumption({
    required String storeId,
    DateTime? from,
    DateTime? to,
  }) async {
    final result = await supabase.rpc(
      'refresh_inventory_daily_consumption',
      params: {
        'p_store_id': storeId,
        'p_from': (from ?? DateTime.now().subtract(const Duration(days: 6)))
            .toIso8601String()
            .split('T')
            .first,
        'p_to': (to ?? DateTime.now()).toIso8601String().split('T').first,
      },
    );
    return (result as num?)?.toInt() ?? 0;
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
          'id, product_id, supplier_id, current_stock_base, avg_daily_consumption_base, target_stock_days, recommended_quantity_base, recommended_order_units, adjusted_quantity_base, adjusted_order_units, adjustment_memo, adjusted_at, estimated_days_remaining, risk_status, created_at, product:inventory_products(id, name, stock_unit, base_unit, base_unit_factor), supplier:inventory_suppliers(id, supplier_name)',
        )
        .eq('run_id', runId)
        .order('recommended_order_units', ascending: false)
        .limit(8);

    final lines = List<Map<String, dynamic>>.from(
      result as List,
    ).map(Map<String, dynamic>.from).toList();
    if (lines.isEmpty) {
      return lines;
    }

    final productIds = lines
        .map((line) => line['product_id']?.toString())
        .whereType<String>()
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList();
    final supplierIds = lines
        .map((line) => line['supplier_id']?.toString())
        .whereType<String>()
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList();
    if (productIds.isEmpty || supplierIds.isEmpty) {
      return lines;
    }

    final supplierItemResult = await supabase
        .from('inventory_supplier_items')
        .select(
          'id, supplier_id, product_id, supplier_sku, order_unit, order_unit_quantity_base, min_order_quantity, unit_price, tax_rate, lead_time_days, is_preferred, is_active, updated_at, product:inventory_products(id, name, stock_unit, base_unit, base_unit_factor), supplier:inventory_suppliers(id, supplier_name)',
        )
        .eq('is_active', true)
        .inFilter('product_id', productIds)
        .inFilter('supplier_id', supplierIds)
        .order('is_preferred', ascending: false)
        .order('updated_at', ascending: false);

    final supplierItemByKey = <String, Map<String, dynamic>>{};
    for (final item in List<Map<String, dynamic>>.from(
      supplierItemResult as List,
    )) {
      final copy = Map<String, dynamic>.from(item);
      final key = _supplierItemRecommendationKey(
        copy['product_id'],
        copy['supplier_id'],
      );
      if (key.isNotEmpty) {
        supplierItemByKey.putIfAbsent(key, () => copy);
      }
    }

    for (final line in lines) {
      final supplierItem =
          supplierItemByKey[_supplierItemRecommendationKey(
            line['product_id'],
            line['supplier_id'],
          )];
      if (supplierItem == null) {
        continue;
      }
      line['supplier_item'] = supplierItem;
      line['order_unit'] = supplierItem['order_unit'];
      line['order_unit_quantity_base'] =
          supplierItem['order_unit_quantity_base'];
      line['min_order_quantity'] = supplierItem['min_order_quantity'];
      line['unit_price'] = supplierItem['unit_price'];
      line['tax_rate'] = supplierItem['tax_rate'];
      line['estimated_amount'] =
          _serviceNum(
            line['adjusted_order_units'] ?? line['recommended_order_units'],
          ) *
          _serviceNum(supplierItem['unit_price']);
    }

    return lines;
  }

  Future<Map<String, dynamic>> updateInventoryRecommendationLineAdjustment({
    required String lineId,
    double? adjustedOrderUnits,
    String? memo,
  }) async {
    final result = await supabase.rpc(
      'update_inventory_recommendation_line_adjustment',
      params: {
        'p_line_id': lineId,
        'p_adjusted_order_units': adjustedOrderUnits,
        'p_adjustment_memo': memo,
      },
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<List<Map<String, dynamic>>> fetchInventorySuppliers({
    required String storeId,
  }) async {
    final brandId = await _fetchStoreBrandId(storeId);
    dynamic query = supabase
        .from('inventory_suppliers')
        .select(
          'id, brand_id, supplier_name, supplier_type, contact_name, phone, email, address, business_registration_no, bank_account_number, payment_terms, contract_start_date, contract_end_date, status, memo, created_at, updated_at',
        );

    if (brandId != null && brandId.isNotEmpty) {
      query = query.or('brand_id.is.null,brand_id.eq.$brandId');
    } else {
      query = query.isFilter('brand_id', null);
    }

    final result = await query.order('supplier_name');
    return List<Map<String, dynamic>>.from(result as List);
  }

  Future<Map<String, dynamic>> upsertInventorySupplier({
    required String storeId,
    String? supplierId,
    required String supplierName,
    String? supplierType,
    String? contactName,
    String? phone,
    String? email,
    String? address,
    String? businessRegistrationNo,
    String? bankAccountNumber,
    String? paymentTerms,
    DateTime? contractStartDate,
    DateTime? contractEndDate,
    String? memo,
  }) async {
    final result = await supabase.rpc(
      'upsert_inventory_supplier',
      params: {
        'p_store_id': storeId,
        'p_supplier_id': supplierId,
        'p_supplier_name': supplierName,
        'p_supplier_type': supplierType,
        'p_contact_name': contactName,
        'p_phone': phone,
        'p_email': email,
        'p_address': address,
        'p_business_registration_no': businessRegistrationNo,
        'p_bank_account_number': bankAccountNumber,
        'p_payment_terms': paymentTerms,
        'p_contract_start_date': contractStartDate
            ?.toIso8601String()
            .split('T')
            .first,
        'p_contract_end_date': contractEndDate
            ?.toIso8601String()
            .split('T')
            .first,
        'p_memo': memo,
      },
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<Map<String, dynamic>> setInventorySupplierStatus({
    required String storeId,
    required String supplierId,
    required String status,
  }) async {
    final result = await supabase.rpc(
      'set_inventory_supplier_status',
      params: {
        'p_store_id': storeId,
        'p_supplier_id': supplierId,
        'p_status': status,
      },
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<List<Map<String, dynamic>>> fetchInventoryProducts({
    required String storeId,
  }) async {
    final result = await supabase
        .from('inventory_products')
        .select(
          'id, restaurant_id, brand_id, inventory_item_id, product_code, name, category, stock_unit, base_unit, base_unit_factor, image_url, storage_type, shelf_life_days, is_orderable, is_active, created_at, updated_at, inventory_item:inventory_items(current_stock, reorder_point, cost_per_unit, supplier_name)',
        )
        .eq('restaurant_id', storeId)
        .order('name');
    return List<Map<String, dynamic>>.from(result as List);
  }

  Future<Map<String, dynamic>> upsertInventoryProduct({
    required String storeId,
    String? productId,
    String? productCode,
    required String name,
    String? category,
    required String stockUnit,
    required String baseUnit,
    required double baseUnitFactor,
    String? imageUrl,
    String? storageType,
    int? shelfLifeDays,
    bool isOrderable = true,
  }) async {
    final result = await supabase.rpc(
      'upsert_inventory_product',
      params: {
        'p_store_id': storeId,
        'p_product_id': productId,
        'p_product_code': productCode,
        'p_name': name,
        'p_category': category,
        'p_stock_unit': stockUnit,
        'p_base_unit': baseUnit,
        'p_base_unit_factor': baseUnitFactor,
        'p_image_url': imageUrl,
        'p_storage_type': storageType,
        'p_shelf_life_days': shelfLifeDays,
        'p_is_orderable': isOrderable,
      },
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<Map<String, dynamic>> setInventoryProductActive({
    required String storeId,
    required String productId,
    required bool isActive,
  }) async {
    final result = await supabase.rpc(
      'set_inventory_product_active',
      params: {
        'p_store_id': storeId,
        'p_product_id': productId,
        'p_is_active': isActive,
      },
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<List<Map<String, dynamic>>> fetchInventorySupplierItems({
    required String storeId,
  }) async {
    final result = await supabase
        .from('inventory_supplier_items')
        .select(
          'id, supplier_id, product_id, supplier_sku, order_unit, order_unit_quantity_base, min_order_quantity, unit_price, tax_rate, lead_time_days, is_preferred, is_active, created_at, updated_at, supplier:inventory_suppliers(id, supplier_name, status), product:inventory_products(id, restaurant_id, name, product_code, category, stock_unit, base_unit, base_unit_factor)',
        )
        .order('updated_at', ascending: false);
    return List<Map<String, dynamic>>.from(result as List)
        .where((row) {
          final product = row['product'];
          return product is Map &&
              product['restaurant_id']?.toString() == storeId;
        })
        .map(Map<String, dynamic>.from)
        .toList();
  }

  Future<Map<String, dynamic>> upsertInventorySupplierItem({
    required String storeId,
    String? supplierItemId,
    required String supplierId,
    required String productId,
    String? supplierSku,
    required String orderUnit,
    required double orderUnitQuantityBase,
    required double minOrderQuantity,
    required double unitPrice,
    required double taxRate,
    required int leadTimeDays,
    required bool isPreferred,
  }) async {
    final result = await supabase.rpc(
      'upsert_inventory_supplier_item',
      params: {
        'p_store_id': storeId,
        'p_supplier_item_id': supplierItemId,
        'p_supplier_id': supplierId,
        'p_product_id': productId,
        'p_supplier_sku': supplierSku,
        'p_order_unit': orderUnit,
        'p_order_unit_quantity_base': orderUnitQuantityBase,
        'p_min_order_quantity': minOrderQuantity,
        'p_unit_price': unitPrice,
        'p_tax_rate': taxRate,
        'p_lead_time_days': leadTimeDays,
        'p_is_preferred': isPreferred,
      },
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<Map<String, dynamic>> setInventorySupplierItemActive({
    required String storeId,
    required String supplierItemId,
    required bool isActive,
  }) async {
    final result = await supabase.rpc(
      'set_inventory_supplier_item_active',
      params: {
        'p_store_id': storeId,
        'p_supplier_item_id': supplierItemId,
        'p_is_active': isActive,
      },
    );
    return Map<String, dynamic>.from(result as Map);
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

  Future<Map<String, dynamic>> createManualInventoryPurchaseOrder({
    required String storeId,
    required String supplierId,
    required List<Map<String, dynamic>> lines,
    DateTime? requestedDeliveryDate,
    String? memo,
  }) async {
    final result = await supabase.rpc(
      'create_manual_inventory_purchase_order',
      params: {
        'p_store_id': storeId,
        'p_supplier_id': supplierId,
        'p_lines': lines,
        'p_requested_delivery_date': requestedDeliveryDate
            ?.toIso8601String()
            .split('T')
            .first,
        'p_memo': memo,
      },
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<Map<String, dynamic>> createRepeatInventoryPurchaseOrder({
    required String sourcePurchaseOrderId,
    DateTime? requestedDeliveryDate,
    String? memo,
  }) async {
    final result = await supabase.rpc(
      'create_repeat_inventory_purchase_order',
      params: {
        'p_source_purchase_order_id': sourcePurchaseOrderId,
        'p_requested_delivery_date': requestedDeliveryDate
            ?.toIso8601String()
            .split('T')
            .first,
        'p_memo': memo,
      },
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<String> saveInventoryStockAudit({
    required String storeId,
    required List<Map<String, dynamic>> lines,
    String? memo,
    required bool complete,
    String? sessionId,
  }) async {
    final result = await supabase.rpc(
      'save_inventory_stock_audit',
      params: {
        'p_store_id': storeId,
        'p_lines': lines,
        'p_memo': memo,
        'p_complete': complete,
        'p_session_id': sessionId,
      },
    );
    return result.toString();
  }

  Future<List<Map<String, dynamic>>> fetchRecentInventoryPurchaseOrders({
    required String storeId,
  }) async {
    final orders = await supabase
        .from('inventory_purchase_orders')
        .select(
          'id, purchase_order_no, status, requested_delivery_date, total_amount, total_supply_amount, tax_amount, created_at, supplier:inventory_suppliers(supplier_name)',
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
          'id, purchase_order_no, status, requested_delivery_date, total_amount, total_supply_amount, tax_amount, memo, created_at, supplier:inventory_suppliers(supplier_name)',
        )
        .eq('id', purchaseOrderId)
        .maybeSingle();

    if (order == null) {
      return null;
    }

    final lines = await supabase
        .from('inventory_purchase_order_lines')
        .select(
          'id, product_id, supplier_item_id, recommended_quantity_base, ordered_quantity_base, ordered_quantity_unit, order_unit, unit_price, supply_amount, tax_amount, memo, recommendation_snapshot, product:inventory_products(name), supplier_item:inventory_supplier_items(supplier_sku, order_unit_quantity_base, min_order_quantity, lead_time_days, is_preferred)',
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

    final supplierItemIds = lineList
        .map((line) => line['supplier_item_id']?.toString())
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList();

    final supplierHistoryLines = supplierItemIds.isEmpty
        ? <Map<String, dynamic>>[]
        : List<Map<String, dynamic>>.from(
            await supabase
                    .from('inventory_purchase_order_lines')
                    .select(
                      'id, purchase_order_id, supplier_item_id, ordered_quantity_base, ordered_quantity_unit, order_unit, unit_price, created_at, product:inventory_products(name), purchase_order:inventory_purchase_orders!inner(id, purchase_order_no, status, created_at)',
                    )
                    .inFilter('supplier_item_id', supplierItemIds)
                    .neq('purchase_order_id', purchaseOrderId)
                    .order('created_at', ascending: false)
                as List,
          );

    final supplierHistoryLineIds = supplierHistoryLines
        .map((line) => line['id']?.toString())
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toList();

    final supplierHistoryReceiptLines = supplierHistoryLineIds.isEmpty
        ? <Map<String, dynamic>>[]
        : List<Map<String, dynamic>>.from(
            await supabase
                    .from('inventory_receipt_lines')
                    .select(
                      'purchase_order_line_id, received_quantity_base, accepted_quantity_base, rejected_quantity_base, receipt:inventory_receipts!inner(status, received_at, created_at)',
                    )
                    .inFilter('purchase_order_line_id', supplierHistoryLineIds)
                as List,
          );

    final supplierHistoryReceiptByLineId = <String, Map<String, dynamic>>{};
    for (final receiptLine in supplierHistoryReceiptLines) {
      final lineId = receiptLine['purchase_order_line_id']?.toString();
      if (lineId == null || lineId.isEmpty) continue;
      final summary = supplierHistoryReceiptByLineId.putIfAbsent(
        lineId,
        () => <String, dynamic>{
          'received_quantity_base': 0.0,
          'accepted_quantity_base': 0.0,
          'rejected_quantity_base': 0.0,
          'last_receipt_status': null,
          'last_receipt_at': null,
        },
      );
      summary['received_quantity_base'] =
          (summary['received_quantity_base'] as double) +
          ((receiptLine['received_quantity_base'] as num?)?.toDouble() ?? 0);
      summary['accepted_quantity_base'] =
          (summary['accepted_quantity_base'] as double) +
          ((receiptLine['accepted_quantity_base'] as num?)?.toDouble() ?? 0);
      summary['rejected_quantity_base'] =
          (summary['rejected_quantity_base'] as double) +
          ((receiptLine['rejected_quantity_base'] as num?)?.toDouble() ?? 0);

      final receiptMap = receiptLine['receipt'] as Map<String, dynamic>?;
      final receiptStatus = receiptMap?['status']?.toString();
      final receiptAt =
          receiptMap?['received_at']?.toString() ??
          receiptMap?['created_at']?.toString();
      final currentLast = summary['last_receipt_at']?.toString();
      if (currentLast == null ||
          (receiptAt != null && receiptAt.compareTo(currentLast) > 0)) {
        summary['last_receipt_at'] = receiptAt;
        summary['last_receipt_status'] = receiptStatus;
      }
    }

    final supplierHistoryBySupplierItemId =
        <String, List<Map<String, dynamic>>>{};
    for (final historyLine in supplierHistoryLines) {
      final supplierItemId = historyLine['supplier_item_id']?.toString();
      final historyLineId = historyLine['id']?.toString();
      if (supplierItemId == null ||
          supplierItemId.isEmpty ||
          historyLineId == null ||
          historyLineId.isEmpty) {
        continue;
      }

      final productMap = historyLine['product'] as Map<String, dynamic>?;
      final purchaseOrderMap =
          historyLine['purchase_order'] as Map<String, dynamic>?;
      final receiptSummary = supplierHistoryReceiptByLineId[historyLineId];
      final entry = <String, dynamic>{
        'purchase_order_id': purchaseOrderMap?['id']?.toString(),
        'purchase_order_no': purchaseOrderMap?['purchase_order_no']?.toString(),
        'order_status': purchaseOrderMap?['status']?.toString() ?? 'submitted',
        'ordered_at':
            purchaseOrderMap?['created_at']?.toString() ??
            historyLine['created_at']?.toString(),
        'product_name':
            productMap?['name']?.toString() ??
            historyLine['product_id']?.toString() ??
            '-',
        'ordered_quantity_base':
            (historyLine['ordered_quantity_base'] as num?)?.toDouble() ?? 0,
        'ordered_quantity_unit':
            (historyLine['ordered_quantity_unit'] as num?)?.toDouble() ?? 0,
        'order_unit': historyLine['order_unit']?.toString() ?? 'unit',
        'unit_price': (historyLine['unit_price'] as num?)?.toDouble() ?? 0,
        'received_quantity_base':
            (receiptSummary?['received_quantity_base'] as num?)?.toDouble() ??
            0,
        'accepted_quantity_base':
            (receiptSummary?['accepted_quantity_base'] as num?)?.toDouble() ??
            0,
        'rejected_quantity_base':
            (receiptSummary?['rejected_quantity_base'] as num?)?.toDouble() ??
            0,
        'last_receipt_status': receiptSummary?['last_receipt_status']
            ?.toString(),
        'last_receipt_at': receiptSummary?['last_receipt_at']?.toString(),
      };
      final bucket = supplierHistoryBySupplierItemId.putIfAbsent(
        supplierItemId,
        () => [],
      );
      if (bucket.length < 3) {
        bucket.add(entry);
      }
    }

    for (final line in lineList) {
      final supplierItemId = line['supplier_item_id']?.toString() ?? '';
      line['supplier_history'] =
          supplierHistoryBySupplierItemId[supplierItemId] ?? const [];
    }

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

    final lineById = <String, Map<String, dynamic>>{};
    for (final line in lineList) {
      final lineId = line['id']?.toString();
      if (lineId != null) {
        lineById[lineId] = line;
      }
    }

    final receiptLineDetailsById = <String, List<Map<String, dynamic>>>{};
    for (final receiptLine in receiptLines) {
      final receiptId = receiptLine['receipt_id']?.toString();
      final purchaseOrderLineId =
          receiptLine['purchase_order_line_id']?.toString() ?? '';
      if (receiptId == null) continue;

      final purchaseOrderLine = lineById[purchaseOrderLineId];
      final snapshot = purchaseOrderLine?['recommendation_snapshot'] is Map
          ? Map<String, dynamic>.from(
              purchaseOrderLine!['recommendation_snapshot'] as Map,
            )
          : null;
      final productMap = purchaseOrderLine?['product'] as Map<String, dynamic>?;
      final supplierItemMap =
          purchaseOrderLine?['supplier_item'] as Map<String, dynamic>?;
      final detail = <String, dynamic>{
        'purchase_order_line_id': purchaseOrderLineId,
        'product_name':
            productMap?['name']?.toString() ??
            purchaseOrderLine?['product_id']?.toString() ??
            receiptLine['product_id']?.toString() ??
            '-',
        'ordered_quantity_base':
            (purchaseOrderLine?['ordered_quantity_base'] as num?)?.toDouble() ??
            0,
        'recommended_quantity_base':
            (purchaseOrderLine?['recommended_quantity_base'] as num?)
                ?.toDouble() ??
            0,
        'received_quantity_base':
            (receiptLine['received_quantity_base'] as num?)?.toDouble() ?? 0,
        'accepted_quantity_base':
            (receiptLine['accepted_quantity_base'] as num?)?.toDouble() ?? 0,
        'rejected_quantity_base':
            (receiptLine['rejected_quantity_base'] as num?)?.toDouble() ?? 0,
        'order_unit': purchaseOrderLine?['order_unit']?.toString() ?? 'unit',
        'line_memo': receiptLine['memo']?.toString(),
        'risk_status': snapshot?['risk_status']?.toString() ?? 'stable',
        'recommendation_run_id': snapshot?['run_id']?.toString(),
        'supplier_sku': supplierItemMap?['supplier_sku']?.toString(),
        'order_unit_quantity_base':
            (supplierItemMap?['order_unit_quantity_base'] as num?)
                ?.toDouble() ??
            0,
        'min_order_quantity':
            (supplierItemMap?['min_order_quantity'] as num?)?.toDouble() ?? 0,
        'lead_time_days':
            (supplierItemMap?['lead_time_days'] as num?)?.toInt() ?? 0,
        'is_preferred': supplierItemMap?['is_preferred'] == true,
      };
      receiptLineDetailsById.putIfAbsent(receiptId, () => []).add(detail);
    }

    final enrichedReceipts = receiptList.map((receipt) {
      final copy = Map<String, dynamic>.from(receipt);
      final receiptId = copy['id']?.toString() ?? '';
      copy['line_count'] = receiptLineCountById[receiptId] ?? 0;
      copy['received_quantity_base'] = receiptReceivedById[receiptId] ?? 0;
      copy['accepted_quantity_base'] = receiptAcceptedById[receiptId] ?? 0;
      copy['rejected_quantity_base'] = receiptRejectedById[receiptId] ?? 0;
      copy['line_details'] = receiptLineDetailsById[receiptId] ?? const [];
      return copy;
    }).toList();

    return {
      'order': orderCopy,
      'lines': lineList,
      'receipts': enrichedReceipts,
    };
  }

  Future<Map<String, dynamic>> confirmInventoryPurchaseReceipt({
    required String purchaseOrderId,
    String? memo,
    List<Map<String, dynamic>> lines = const [],
  }) async {
    final result = await supabase.rpc(
      'confirm_inventory_purchase_receipt',
      params: {
        'p_purchase_order_id': purchaseOrderId,
        'p_memo': memo,
        'p_lines': lines,
      },
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<List<Map<String, dynamic>>> _rpcList(
    String functionName, {
    required Map<String, dynamic> params,
  }) async {
    final result = await supabase.rpc(functionName, params: params);
    return List<Map<String, dynamic>>.from(result as List);
  }

  String _supplierItemRecommendationKey(Object? productId, Object? supplierId) {
    final product = productId?.toString() ?? '';
    final supplier = supplierId?.toString() ?? '';
    return product.isEmpty || supplier.isEmpty ? '' : '$product::$supplier';
  }

  num _serviceNum(Object? value) {
    if (value is num) return value;
    return num.tryParse(value?.toString() ?? '') ?? 0;
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

  Future<String?> _fetchStoreBrandId(String storeId) async {
    final result = await supabase
        .from('restaurants')
        .select('brand_id')
        .eq('id', storeId)
        .maybeSingle();
    return result?['brand_id']?.toString();
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
