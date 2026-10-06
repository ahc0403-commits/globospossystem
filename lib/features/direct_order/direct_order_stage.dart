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
