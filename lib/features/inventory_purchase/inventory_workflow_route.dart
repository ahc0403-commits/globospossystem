String inventoryWorkflowLocation({String? storeId, String? orderId}) => Uri(
  path: orderId == null ? '/inventory-orders' : '/inventory-orders/$orderId',
  queryParameters: storeId == null ? null : {'storeId': storeId},
).toString();
