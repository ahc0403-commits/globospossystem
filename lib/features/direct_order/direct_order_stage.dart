enum DirectOrderStage {
  waiting('customer_pending'),
  paid('customer_paid'),
  completed('customer_completed'),
  exception('customer_exception');

  const DirectOrderStage(this.filter);
  final String filter;
}

/// Display projection only. Payment proof never establishes payment completion.
DirectOrderStage directOrderStage(String state, String? fulfillmentStatus) {
  if (const {'rejected', 'cancelled', 'expired'}.contains(state) ||
      fulfillmentStatus == 'cancelled') {
    return DirectOrderStage.exception;
  }
  if (state == 'approved') {
    return fulfillmentStatus == 'completed'
        ? DirectOrderStage.completed
        : DirectOrderStage.paid;
  }
  return DirectOrderStage.waiting;
}

/// Customer progress is separate from the cashier's payment/filter grouping.
/// Cooking completion comes from all active KDS quantities, never elapsed time.
String directOrderCustomerProgress(
  String state,
  String? fulfillmentStatus, {
  bool cookingComplete = false,
  bool isPickup = false,
  bool handoffConfirmed = false,
  bool driverBooked = false,
}) {
  if (fulfillmentStatus == 'cancelled') return 'cancelled';
  if (const {'rejected', 'cancelled', 'expired'}.contains(state)) return state;
  if (state != 'approved') return state;
  return switch (fulfillmentStatus) {
    'completed' => isPickup ? 'customer_collected' : 'customer_delivered',
    'dispatched' =>
      isPickup
          ? 'customer_pickup_ready'
          : handoffConfirmed
          ? 'customer_shipping'
          : 'customer_packed',
    'ready' => isPickup ? 'customer_pickup_ready' : 'customer_packed',
    _ =>
      driverBooked && !isPickup
          ? 'customer_driver_booked'
          : cookingComplete
          ? 'customer_cooked'
          : 'customer_preparing',
  };
}
