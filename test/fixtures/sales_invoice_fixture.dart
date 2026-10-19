/// Explicit synthetic approvals for old, unrelated receipt/contact fixtures.
/// Invalid-source contract tests use the writer directly without this helper.
Map<String, dynamic> approvedSalesFixtureLine(
  Map<String, dynamic> line, {
  String storeId = 'fixture-store',
}) {
  final q = line['quantity'] as num? ?? 1;
  final supply = line['total_amount_ex_tax'] as num? ?? 0;
  final wet = line['item_type'] == 'wet_tissue_charge';
  return {
    'menu_item_id': wet ? null : 'fixture-menu',
    'invoice_profile_id': 'fixture-approved-profile',
    'invoice_approval_type': wet ? 'item_type' : 'menu_item',
    'invoice_mapping_version': 'fixture-v1',
    'invoice_source_reference': 'synthetic approved fixture',
    'invoice_effective_from': '2020-01-01T00:00:00+07:00',
    'invoice_effective_to': null,
    'invoice_store_id': storeId,
    'unit_price': supply / q,
    'misa_unit_price': supply / q,
    'misa_discount_amount': 0,
    'vat_rate': 0,
    'vat_amount': 0,
    ...line,
  };
}

List<Map<String, dynamic>> approvedSalesFixtureJobs(
  List<Map<String, dynamic>> jobs,
) => [
  for (var i = 0; i < jobs.length; i++)
    {
      'receipt_id': 'fixture-receipt-$i',
      'created_at': '2026-10-08T12:00:00+07:00',
      ...jobs[i],
      'line_items_snapshot': [
        for (final l in jobs[i]['line_items_snapshot'] as List? ?? [])
          if (jobs[i]['source_system'] == 'photo_objet_moers')
            {...l, 'order_item_id': 'fixture-photo-$i'}
          else
            approvedSalesFixtureLine(Map<String, dynamic>.from(l as Map)),
      ],
    },
];
Map<String, dynamic> approvedSalesFixturePayload(Map<String, dynamic> payload) {
  for (final receipt in payload['receipts'] as List? ?? []) {
    receipt['line_items'] = [
      for (final l in receipt['line_items'] as List? ?? [])
        approvedSalesFixtureLine(
          Map<String, dynamic>.from(l as Map),
          storeId: '${receipt['store_id']}',
        ),
    ];
  }
  for (final e in payload['entities'] as List? ?? []) {
    approvedSalesFixturePayload(Map<String, dynamic>.from(e as Map));
  }
  return payload;
}
