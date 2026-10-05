import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Supplier documents render only the explicitly allowed projection fields.
Future<Uint8List> buildProcurementDocumentPdf(
  Map<String, dynamic> document, {
  required Map<String, String> labels,
  required String fontAsset,
}) async {
  final data = Map<String, dynamic>.from(document['data'] as Map);
  final supplier =
      document['kind'] == 'po' && document['audience'] == 'supplier';
  if (document['kind'] == 'po' && !supplier) {
    throw StateError('PROCUREMENT_INTERNAL_RENDERER_REQUIRED');
  }
  final font = pw.Font.ttf(await rootBundle.load(fontAsset));
  final doc = pw.Document(
    theme: pw.ThemeData.withFont(base: font, bold: font),
  );
  String text(dynamic value) => value?.toString() ?? '—';
  final lines = (data['lines'] as List? ?? []).whereType<Map>().toList();
  final dates = labels['dates']!
      .replaceAll('{0}', text(data['pr_created_at'] ?? data['created_at']))
      .replaceAll('{1}', text(data['pr_submitted_at'] ?? data['submitted_at']))
      .replaceAll('{2}', text(data['issued_at']));
  num number(dynamic v) =>
      v is num ? v : num.tryParse(v?.toString() ?? '') ?? 0;
  num? estimate(Map line) {
    final price = num.tryParse(line['estimated_unit_price']?.toString() ?? '');
    final conversion = num.tryParse(
      line['estimated_conversion']?.toString() ?? '',
    );
    if (price == null || conversion == null || conversion <= 0) return null;
    return number(line['quantity_base']) / conversion * price;
  }

  final complete =
      data['estimates_complete'] as bool? ??
      lines.every((line) => estimate(line) != null);
  final net = lines.fold<num>(0, (sum, line) => sum + (estimate(line) ?? 0));
  final vat = lines.fold<num>(
    0,
    (sum, line) =>
        sum + (estimate(line) ?? 0) * number(line['estimated_tax_rate']) / 100,
  );
  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      maxPages: 100,
      build: (_) => [
        pw.Text(
          labels[supplier ? 'titlePo' : 'titlePr']!,
          style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold),
        ),
        pw.Text(text(data[supplier ? 'purchase_order_no' : 'request_no'])),
        pw.Text(text(data['store_name'])),
        pw.Text(dates),
        pw.Text(text(data['requested_delivery_date'])),
        if (supplier) ...[
          pw.Text(text(data['supplier_name'])),
          pw.Text(text(data['delivery_address'])),
          pw.Text(text(data['contact_name'])),
        ] else ...[
          pw.Text(
            '${labels['category']}: ${labels[text(data['purchase_category'])] ?? text(data['purchase_category'])}',
          ),
          pw.Text(
            '${labels['channel']}: ${labels[text(data['purchase_channel'])] ?? text(data['purchase_channel'])}',
          ),
          pw.Text('${labels['reason']}: ${text(data['reason'])}'),
        ],
        pw.SizedBox(height: 16),
        pw.TableHelper.fromTextArray(
          headers: [
            labels['item']!,
            labels['specification']!,
            labels['quantity']!,
            labels['unit']!,
            labels['notes']!,
            if (!supplier) ...[
              labels['estimate']!,
              labels['amount']!,
              labels['stock']!,
            ],
          ],
          data: lines
              .map(
                (l) => [
                  text(l['product_name']),
                  text(
                    l[supplier ? 'specification' : 'specification_snapshot'],
                  ),
                  text(l[supplier ? 'quantity' : 'requested_quantity']),
                  text(l[supplier ? 'unit' : 'requested_unit']),
                  text(l['memo']),
                  if (!supplier) ...[
                    '${text(l['estimated_unit_price'])} / ${text(l['estimated_order_unit'])}',
                    estimate(l)?.toStringAsFixed(2) ?? '—',
                    text(l['current_stock_snapshot']),
                  ],
                ],
              )
              .toList(),
        ),
        if (!supplier) ...[
          pw.SizedBox(height: 16),
          pw.Text(
            '${labels['expectedVat']}: ${complete ? number(data['estimated_vat'] ?? vat).toStringAsFixed(2) : '—'} VND',
          ),
          pw.Text(
            '${labels['expectedTotal']}: ${complete ? number(data['estimated_total'] ?? (net + vat)).toStringAsFixed(2) : '—'} VND',
          ),
          for (final stage in ['store', 'brand', 'office'])
            pw.Text(
              '${labels[stage == 'store'
                  ? 'approveStore'
                  : stage == 'brand'
                  ? 'approveBrand'
                  : 'approvePurchase']}: ${text((data['${stage}_approved_actor'] as Map?)?['display_name'] ?? (data['${stage}_approved_actor'] as Map?)?['role'])} · ${text(data['${stage}_approved_at'])}',
            ),
          pw.Text(text(data['memo'])),
        ],
      ],
    ),
  );
  return doc.save();
}
