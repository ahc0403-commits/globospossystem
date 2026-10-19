import 'package:flutter/material.dart';

class ProcurementMetrics extends StatelessWidget {
  const ProcurementMetrics({
    super.key,
    required this.data,
    required this.label,
  });
  final Map<String, dynamic> data;
  final String Function(String) label;
  @override
  Widget build(BuildContext context) {
    final requests = data['requests'] as Map? ?? {};
    final orders = data['orders'] as Map? ?? {};
    final values = <String, dynamic>{
      'storeWaiting': requests['store_wait'],
      'brandWaiting': requests['brand_wait'],
      'purchaseWaiting': requests['purchase_wait'],
      'waitingP95': requests['waiting_p95_hours'],
      'supplierDocuments': orders['price_free_documents'],
      'accountingHolds': orders['accounting_holds'],
      'inspectionWaiting': (data['receipts'] as Map?)?['inspection_wait'],
      'openIssues': (data['issues'] as Map?)?['open_issues'],
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${label('observedAt')}: ${data['as_of'] ?? ''} · ${data['window_days'] ?? 90} d',
        ),
        Wrap(
          spacing: 16,
          runSpacing: 8,
          children: [
            for (final v in values.entries)
              SizedBox(
                width: 240,
                child: Text(
                  '${label(v.key)}: ${v.value is num ? (v.value as num).toStringAsFixed(1) : v.value ?? '—'}',
                ),
              ),
          ],
        ),
        if ((data['missing_stages'] as List? ?? []).isNotEmpty)
          Text(
            '${label('missingRoles')}: ${(data['missing_stages'] as List).map((s) => label('role_$s')).join(', ')}',
          ),
        for (final row in (data['role_roster'] as List? ?? []))
          Text(
            '${label('role_${row['stage']}')} · ${row['display_name']} · ${row['system']} · ${row['valid_from']} → ${row['valid_until']}',
          ),
      ],
    );
  }
}
