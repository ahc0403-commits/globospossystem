import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'procurement_presentation.dart';
import 'procurement_process_labels.dart';
import 'procurement_request_lines.dart';

/// Supplier documents render only the explicitly allowed projection fields.
Future<Uint8List> buildProcurementDocumentPdf(
  Map<String, dynamic> document, {
  required Map<String, String> labels,
  required String fontAsset,
  DateTime? printedAt,
}) async {
  final data = Map<String, dynamic>.from(document['data'] as Map);
  final supplier =
      document['kind'] == 'po' && document['audience'] == 'supplier';
  final requestHeader = supplier ? null : procurementRequestHeader(data);
  if (document['kind'] == 'po' && !supplier) {
    throw StateError('PROCUREMENT_INTERNAL_RENDERER_REQUIRED');
  }
  final font = pw.Font.ttf(await rootBundle.load(fontAsset));
  final doc = pw.Document(
    theme: pw.ThemeData.withFont(base: font, bold: font),
  );
  String copy(String key) => labels[key] ?? procurementProcessLabel(key, 'en');
  String text(dynamic value) => value?.toString() ?? '—';
  num number(dynamic value) =>
      value is num ? value : num.tryParse(value?.toString() ?? '') ?? 0;
  final sourceLines = (data['lines'] as List? ?? []).whereType<Map>();
  final lines = supplier
      ? sourceLines.toList()
      : procurementSortedRequestLines(sourceLines);
  num? estimate(Map line) {
    if (line['estimated_amount'] != null) {
      return number(line['estimated_amount']);
    }
    final price = num.tryParse(line['estimated_unit_price']?.toString() ?? '');
    final conversion = num.tryParse(
      line['estimated_conversion']?.toString() ?? '',
    );
    if (price == null || conversion == null || conversion <= 0) return null;
    return num.parse(
      (number(line['quantity_base']) / conversion * price).toStringAsFixed(2),
    );
  }

  final complete =
      data['estimates_complete'] as bool? ??
      lines.every((line) => estimate(line) != null);
  final net = lines.fold<num>(0, (sum, line) => sum + (estimate(line) ?? 0));
  final vat = lines.fold<num>(
    0,
    (sum, line) =>
        sum +
        num.parse(
          ((estimate(line) ?? 0) * number(line['estimated_tax_rate']) / 100)
              .toStringAsFixed(2),
        ),
  );
  String carryText(Map line) {
    final sources = (line['shortage_sources'] as List? ?? []);
    if (sources.isEmpty) return '';
    return '\n${copy('carryShortage')}: ${procurementNumber(line['shortage_quantity'], decimals: 3)} ${text(line[supplier ? 'unit' : 'requested_unit'])} · ${sources.map((s) => s['purchase_order_no']).where((s) => s != null).join(', ')}';
  }

  String internalItem(Map line) {
    final code = procurementMaterialCode(line);
    final specification = line['specification_snapshot']?.toString() ?? '';
    return '${text(line['product_name'])}${code.isEmpty ? '' : '\n$code'}${carryText(line)}${specification.isEmpty ? '' : '\n$specification'}';
  }

  final tableRows = [
    for (var i = 0; i < lines.length; i++)
      if (supplier)
        [
          '${text(lines[i]['product_name'])}\n${copy('productCode')}: ${text(lines[i]['product_code'])}${carryText(lines[i])}',
          text(lines[i]['specification']),
          procurementNumber(lines[i]['quantity'], decimals: 3),
          text(lines[i]['unit']),
          text(lines[i]['memo']),
        ]
      else
        [
          '${i + 1}',
          internalItem(lines[i]),
          procurementNumber(lines[i]['requested_quantity'], decimals: 3),
          text(lines[i]['requested_unit']),
          procurementNumber(lines[i]['current_stock_snapshot'], decimals: 3),
          lines[i]['estimated_unit_price'] == null
              ? copy('quoteNeeded')
              : procurementNumber(procurementDisplayUnitPrice(lines[i])),
          estimate(lines[i]) == null
              ? copy('quoteNeeded')
              : procurementNumber(estimate(lines[i])),
          text(lines[i]['memo']),
        ],
  ];
  final scalarWidths = <int, double>{
    0: 35,
    2: 62,
    3: 72,
    4: 66,
    5: 84,
    6: 84,
    7: 71,
  };
  var itemWidth = 151.0;
  if (!supplier) {
    final metrics = font.getFont(pw.Context(document: doc.document));
    final headers = [
      copy('lineNo'),
      copy('item'),
      copy('quantity'),
      copy('unit'),
      copy('stock'),
      copy('estimate'),
      copy('amount'),
      copy('notes'),
    ];
    for (final row in [headers, ...tableRows]) {
      for (var column = 0; column < 7; column++) {
        for (final line in row[column].toString().split('\n')) {
          final required = metrics.stringMetrics(line).advanceWidth * 8 + 12;
          if (column == 1) {
            if (required > itemWidth) itemWidth = required;
          } else if (required > scalarWidths[column]!) {
            scalarWidths[column] = required;
          }
        }
      }
    }
  }
  final requiredWidth =
      scalarWidths.values.fold<double>(itemWidth, (a, b) => a + b) + 72;
  final prFormat = requiredWidth <= PdfPageFormat.a4.landscape.width
      ? PdfPageFormat.a4.landscape
      : requiredWidth <= PdfPageFormat.a3.landscape.width
      ? PdfPageFormat.a3.landscape
      : PdfPageFormat(requiredWidth, PdfPageFormat.a3.landscape.height);
  final no = text(data[supplier ? 'purchase_order_no' : 'request_no']);
  final ink = PdfColor.fromHex('#172B3B');
  final pale = PdfColor.fromHex('#EFF4F7');
  final blue = PdfColor.fromHex('#246596');
  pw.Widget info(String label, dynamic value, {String? detail}) => pw.Padding(
    padding: const pw.EdgeInsets.all(8),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(
          label,
          style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
        ),
        pw.SizedBox(height: 3),
        pw.Text(text(value), style: const pw.TextStyle(fontSize: 10)),
        if (detail != null && detail.isNotEmpty) ...[
          pw.SizedBox(height: 3),
          pw.Text(detail, style: const pw.TextStyle(fontSize: 9)),
        ],
      ],
    ),
  );
  pw.Widget sumRow(
    String label,
    dynamic value, {
    bool total = false,
  }) => pw.Container(
    color: total ? pale : null,
    padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 5),
    child: pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Text(label),
        pw.Text(
          '${complete ? procurementNumber(value) : copy('estimatePending')} VND',
        ),
      ],
    ),
  );
  doc.addPage(
    pw.MultiPage(
      pageFormat: supplier ? PdfPageFormat.a4 : prFormat,
      margin: const pw.EdgeInsets.fromLTRB(36, 30, 36, 40),
      maxPages: 100,
      theme: pw.ThemeData.withFont(
        base: font,
        bold: font,
      ).copyWith(defaultTextStyle: pw.TextStyle(fontSize: 9, color: ink)),
      header: (context) => context.pageNumber == 1
          ? pw.SizedBox()
          : pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 10),
              child: pw.Text(
                '${copy(supplier ? 'titlePo' : 'titlePr')} · $no',
                style: const pw.TextStyle(fontSize: 10),
              ),
            ),
      footer: (context) => pw.Padding(
        padding: const pw.EdgeInsets.only(top: 10),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(
              '${copy('printedAt')}: ${procurementDate((printedAt ?? DateTime.now().toUtc()).toIso8601String(), includeTime: true)}',
              style: const pw.TextStyle(fontSize: 7),
            ),
            pw.Text(
              '${context.pageNumber} / ${context.pagesCount}',
              style: const pw.TextStyle(fontSize: 7),
            ),
          ],
        ),
      ),
      build: (_) => [
        pw.Text(
          copy(supplier ? 'titlePo' : 'titlePr'),
          style: pw.TextStyle(fontSize: 23, fontWeight: pw.FontWeight.bold),
        ),
        pw.SizedBox(height: 8),
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(no),
            if (!supplier) pw.Text(copy(data['status']?.toString() ?? 'draft')),
          ],
        ),
        pw.Divider(color: blue),
        pw.Container(
          color: pale,
          child: pw.Table(
            children: [
              pw.TableRow(
                children: [
                  info(
                    copy('store'),
                    requestHeader?['store_name'] ?? data['store_name'],
                    detail: requestHeader?['store_address'],
                  ),
                  info(
                    copy('requestDate'),
                    procurementDate(
                      data['pr_created_at'] ?? data['created_at'],
                    ),
                  ),
                  info(
                    copy('requiredDate'),
                    procurementDate(data['requested_delivery_date']),
                  ),
                ],
              ),
              if (!supplier)
                pw.TableRow(
                  children: [
                    info(
                      copy(requestHeader?['requester_label'] ?? 'requester'),
                      requestHeader?['requester_value'],
                    ),
                    info(
                      copy('category'),
                      copy(
                        data['purchase_category']?.toString() ?? 'raw_material',
                      ),
                    ),
                    info(copy('lineCount'), '${lines.length}'),
                  ],
                ),
            ],
          ),
        ),
        pw.SizedBox(height: 10),
        if (supplier) ...[
          pw.Text(
            copy('dates')
                .replaceAll(
                  '{0}',
                  procurementDate(data['pr_created_at'] ?? data['created_at']),
                )
                .replaceAll(
                  '{1}',
                  procurementDate(
                    data['pr_submitted_at'] ?? data['submitted_at'],
                  ),
                )
                .replaceAll('{2}', procurementDate(data['issued_at'])),
          ),
          pw.Text(text(data['supplier_name'])),
          pw.Text(text(data['delivery_address'])),
          pw.Text(text(data['contact_name'])),
        ] else ...[
          pw.Text('${copy('reason')}: ${text(data['reason'])}'),
          if (data['memo'] != null && data['memo'].toString().isNotEmpty)
            pw.Text('${copy('notes')}: ${data['memo']}'),
        ],
        pw.SizedBox(height: 12),
        pw.TableHelper.fromTextArray(
          headers: supplier
              ? [
                  copy('item'),
                  copy('specification'),
                  copy('quantity'),
                  copy('unit'),
                  copy('notes'),
                ]
              : [
                  copy('lineNo'),
                  copy('item'),
                  copy('quantity'),
                  copy('unit'),
                  copy('stock'),
                  copy('estimate'),
                  copy('amount'),
                  copy('notes'),
                ],
          headerStyle: pw.TextStyle(
            fontSize: 8,
            fontWeight: pw.FontWeight.bold,
          ),
          cellStyle: const pw.TextStyle(fontSize: 8),
          cellBuilder: (column, value, row) =>
              (supplier ? column == 3 : [0, 2, 3, 4, 5, 6].contains(column))
              ? pw.Text(
                  value.toString(),
                  style: const pw.TextStyle(fontSize: 8),
                  maxLines: 1,
                )
              : null,
          cellPadding: const pw.EdgeInsets.symmetric(
            horizontal: 5,
            vertical: 7,
          ),
          headerDecoration: pw.BoxDecoration(color: pale),
          border: const pw.TableBorder(
            horizontalInside: pw.BorderSide(
              color: PdfColors.grey300,
              width: .4,
            ),
          ),
          columnWidths: supplier
              ? {
                  0: const pw.FlexColumnWidth(3),
                  1: const pw.FlexColumnWidth(),
                  2: const pw.FlexColumnWidth(),
                  3: const pw.FlexColumnWidth(),
                  4: const pw.FlexColumnWidth(2),
                }
              : {
                  for (final entry in scalarWidths.entries)
                    entry.key: pw.FixedColumnWidth(entry.value),
                  1: const pw.FlexColumnWidth(),
                },
          cellAlignments: supplier
              ? {2: pw.Alignment.topRight}
              : {
                  0: pw.Alignment.topCenter,
                  2: pw.Alignment.topRight,
                  3: pw.Alignment.topCenter,
                  4: pw.Alignment.topRight,
                  5: pw.Alignment.topRight,
                  6: pw.Alignment.topRight,
                },
          data: tableRows,
        ),
        if (!supplier)
          pw.Table(
            children: [
              pw.TableRow(
                children: [
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.stretch,
                    children: [
                      pw.SizedBox(height: 12),
                      pw.Column(
                        children: [
                          sumRow(
                            copy('estimatedNet'),
                            data['estimated_net'] ?? net,
                          ),
                          sumRow(
                            copy('expectedVat'),
                            data['estimated_vat'] ?? vat,
                          ),
                          sumRow(
                            copy('expectedTotal'),
                            data['estimated_total'] ?? net + vat,
                            total: true,
                          ),
                        ],
                      ),
                      pw.SizedBox(height: 5),
                      pw.Text(
                        copy('estimateNote'),
                        style: const pw.TextStyle(fontSize: 8),
                      ),
                      pw.SizedBox(height: 12),
                      pw.TableHelper.fromTextArray(
                        headers: [
                          copy('stage'),
                          copy('approver'),
                          copy('status'),
                          copy('approvedAt'),
                        ],
                        headerStyle: pw.TextStyle(
                          fontSize: 8,
                          fontWeight: pw.FontWeight.bold,
                        ),
                        cellStyle: const pw.TextStyle(fontSize: 8),
                        cellBuilder: (column, value, row) =>
                            column == (supplier ? 3 : 3)
                            ? pw.FittedBox(
                                fit: pw.BoxFit.scaleDown,
                                child: pw.Text(
                                  value.toString(),
                                  style: const pw.TextStyle(fontSize: 8),
                                ),
                              )
                            : null,
                        headerDecoration: pw.BoxDecoration(color: pale),
                        columnWidths: {
                          0: const pw.FlexColumnWidth(2),
                          1: const pw.FlexColumnWidth(2),
                          2: const pw.FlexColumnWidth(),
                          3: const pw.FlexColumnWidth(2),
                        },
                        data: [
                          for (final stage
                              in (data['approval_policy_version'] == 3
                                  ? ['store', 'office']
                                  : ['store', 'brand', 'office']))
                            [
                              copy(
                                stage == 'store'
                                    ? 'approveStore'
                                    : stage == 'brand'
                                    ? 'approveBrand'
                                    : 'approvePurchase',
                              ),
                              text(
                                (data['${stage}_approved_actor']
                                        as Map?)?['display_name'] ??
                                    (data['${stage}_approved_actor']
                                        as Map?)?['role'],
                              ),
                              data['${stage}_approved_at'] == null
                                  ? copy('pending')
                                  : copy('approved'),
                              procurementDate(
                                data['${stage}_approved_at'],
                                includeTime: true,
                              ),
                            ],
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
      ],
    ),
  );
  return doc.save();
}
