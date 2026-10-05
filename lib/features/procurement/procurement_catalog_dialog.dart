import 'package:flutter/material.dart';

class ProcurementCatalogDialog extends StatefulWidget {
  const ProcurementCatalogDialog({
    super.key,
    required this.label,
    required this.suppliers,
  });
  final String Function(String) label;
  final Map<String, String> suppliers;
  @override
  State<ProcurementCatalogDialog> createState() => _CatalogState();
}

class _CatalogState extends State<ProcurementCatalogDialog> {
  final form = GlobalKey<FormState>();
  final values = <String, String>{
    'base_unit': 'ea',
    'stock_unit': 'ea',
    'base_unit_factor': '1',
    'tax_rate': '0',
  };
  String classification = 'nonstock';
  String? supplier;
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.label('catalogSetup')),
    content: SizedBox(
      width: 540,
      child: SingleChildScrollView(
        child: Form(
          key: form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final field in {
                'name': 'item',
                'product_code': 'productCode',
                'specification': 'specification',
                'stock_unit': 'unit',
                'base_unit_factor': 'factor',
                'unit_price': 'estimate',
                'tax_rate': 'vat',
              }.entries)
                TextFormField(
                  initialValue: values[field.key],
                  decoration: InputDecoration(
                    labelText: widget.label(field.value),
                  ),
                  onChanged: (v) => values[field.key] = v,
                  validator: (v) {
                    if (field.key == 'specification') {
                      return null;
                    }
                    if ([
                      'base_unit_factor',
                      'unit_price',
                      'tax_rate',
                    ].contains(field.key)) {
                      final n = num.tryParse(v ?? '');
                      if (n == null ||
                          !n.isFinite ||
                          n < 0 ||
                          field.key != 'tax_rate' && n == 0 ||
                          field.key == 'tax_rate' && n > 100) {
                        return widget.label(field.value);
                      }
                    } else if (v == null || v.trim().isEmpty) {
                      return widget.label(field.value);
                    }
                    return null;
                  },
                ),
              DropdownButtonFormField<String>(
                initialValue: 'ea',
                decoration: InputDecoration(
                  labelText: widget.label('baseUnit'),
                ),
                items: [
                  for (final u in ['ea', 'g', 'ml'])
                    DropdownMenuItem(value: u, child: Text(u)),
                ],
                onChanged: (v) => values['base_unit'] = v!,
              ),
              DropdownButtonFormField<String>(
                initialValue: classification,
                decoration: InputDecoration(
                  labelText: widget.label('receiptClass'),
                ),
                items: [
                  for (final c in ['nonstock', 'asset'])
                    DropdownMenuItem(value: c, child: Text(widget.label(c))),
                ],
                onChanged: (v) => classification = v!,
              ),
              DropdownButtonFormField<String>(
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: widget.label('supplierPdf'),
                ),
                items: [
                  for (final s in widget.suppliers.entries)
                    DropdownMenuItem(value: s.key, child: Text(s.value)),
                ],
                onChanged: (v) => supplier = v,
                validator: (v) =>
                    v == null ? widget.label('supplierPdf') : null,
              ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Icon(Icons.close),
      ),
      FilledButton(
        onPressed: () {
          if (form.currentState!.validate()) {
            Navigator.pop(context, {
              ...values,
              'supplier_id': supplier,
              'receipt_classification': classification,
            });
          }
        },
        child: const Icon(Icons.check),
      ),
    ],
  );
}

class ProcurementChannelDialog extends StatefulWidget {
  const ProcurementChannelDialog({
    super.key,
    required this.label,
    required this.order,
  });
  final String Function(String) label;
  final Map<String, dynamic> order;
  @override
  State<ProcurementChannelDialog> createState() => _ChannelState();
}

class _ChannelState extends State<ProcurementChannelDialog> {
  final form = GlobalKey<FormState>();
  final values = <String, String>{};
  String kind = 'advance', paidBy = 'company';
  @override
  void initState() {
    super.initState();
    values['external_order_no'] =
        (widget.order['commercial_terms'] as Map?)?['external_order_no']
            ?.toString() ??
        '';
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.label('channelRecord')),
    content: SizedBox(
      width: 540,
      child: SingleChildScrollView(
        child: Form(
          key: form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: kind,
                decoration: InputDecoration(
                  labelText: widget.label('channelKind'),
                ),
                items: [
                  for (final k in ['advance', 'refund', 'reimbursement'])
                    DropdownMenuItem(value: k, child: Text(widget.label(k))),
                ],
                onChanged: (v) => kind = v!,
              ),
              DropdownButtonFormField<String>(
                initialValue: paidBy,
                items: [
                  for (final k in ['company', 'employee'])
                    DropdownMenuItem(value: k, child: Text(widget.label(k))),
                ],
                onChanged: (v) => paidBy = v!,
              ),
              for (final field in {
                'external_order_no': 'externalOrder',
                'amount': 'amount',
                'payment_reference': 'paymentReference',
                'evidence_reference': 'paymentEvidence',
              }.entries)
                TextFormField(
                  initialValue: values[field.key],
                  decoration: InputDecoration(
                    labelText: widget.label(field.value),
                  ),
                  onChanged: (v) => values[field.key] = v,
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) {
                      return widget.label(field.value);
                    }
                    if (field.key == 'amount') {
                      final n = num.tryParse(v);
                      if (n == null || !n.isFinite || n <= 0) {
                        return widget.label('amount');
                      }
                    }
                    return null;
                  },
                ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Icon(Icons.close),
      ),
      FilledButton(
        onPressed: () {
          if (form.currentState!.validate()) {
            Navigator.pop(context, {
              ...values,
              'kind': kind,
              'paid_by': paidBy,
            });
          }
        },
        child: const Icon(Icons.check),
      ),
    ],
  );
}
