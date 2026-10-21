import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'procurement_presentation.dart';

Future<Uint8List> buildProcurementReceiptReportPdf(
  Map<String, dynamic> report, {
  required String language,
  required String fontAsset,
}) async {
  final data = Map<String, dynamic>.from(report['data'] as Map);
  String t(String ko, String en, String vi) => switch (language) {
    'ko' => ko,
    'vi' => vi,
    _ => en,
  };
  final complete = report['kind'] == 'complete';
  final release = data['receipt_origin'] == 'hold_release';
  final held = (data['lines'] as List).any(
    (l) => (l['held_quantity'] as num? ?? 0) > 0,
  );
  final title = release
      ? t(
          '보류 재검수 확인서',
          'Held stock reinspection',
          'Xác nhận kiểm tra lại hàng tạm giữ',
        )
      : complete
      ? t(
          '전량 입고 확인서',
          'Complete delivery confirmation',
          'Xác nhận nhập đủ hàng',
        )
      : t(
          'PO 대비 입고 수량 차이서',
          'PO delivery discrepancy report',
          'Biên bản chênh lệch nhập hàng',
        );
  final font = pw.Font.ttf(await rootBundle.load(fontAsset));
  final doc = pw.Document(
    theme: pw.ThemeData.withFont(base: font, bold: font),
  );
  final lines = (data['lines'] as List).cast<Map>();
  final headers = [
    t('원료코드·품목', 'Material code / item', 'Mã / nguyên liệu'),
    t('단위', 'Unit', 'Đơn vị'),
    t('PO 수량', 'Ordered', 'Đặt'),
    if (!complete) t('이전 입고', 'Previous', 'Trước'),
    if (!complete) t('이번 실수령', 'Received', 'Nhận lần này'),
    if (release) t('보류 해제', 'Released', 'Đã giải phóng'),
    if (held) t('보류', 'Held', 'Tạm giữ'),
    t('누적 합격', 'Accepted total', 'Tổng nhập đạt'),
    if (!complete) t('부족', 'Short', 'Thiếu'),
    if (!complete) t('초과', 'Excess', 'Thừa'),
    if (!complete) t('불합격', 'Rejected', 'Không đạt'),
  ];
  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(30),
      maxPages: 100,
      header: (_) => pw.Text(
        '$title · ${data['purchase_order_no']}',
        style: const pw.TextStyle(fontSize: 12),
      ),
      footer: (c) => pw.Text(
        '${c.pageNumber} / ${c.pagesCount}',
        style: const pw.TextStyle(fontSize: 8),
      ),
      build: (_) => [
        pw.SizedBox(height: 12),
        pw.Text('${data['store_name']} · ${data['supplier_name']}'),
        pw.Text(
          '${t('검수 담당자', 'Inspector', 'Người kiểm nhận')}: ${data['inspector_name']}',
        ),
        pw.Text(
          '${t('입고 확정', 'Confirmed', 'Xác nhận')}: ${procurementDate(data['confirmed_at'], includeTime: true)} · ${t('입고 회차', 'Delivery', 'Lần giao')}: ${data['delivery_cycle']}',
        ),
        pw.SizedBox(height: 12),
        pw.TableHelper.fromTextArray(
          headers: headers,
          headerCount: 1,
          cellStyle: const pw.TextStyle(fontSize: 7),
          headerStyle: pw.TextStyle(
            fontSize: 7,
            fontWeight: pw.FontWeight.bold,
          ),
          cellPadding: const pw.EdgeInsets.all(4),
          headerDecoration: const pw.BoxDecoration(color: PdfColors.grey200),
          columnWidths: {
            0: const pw.FlexColumnWidth(3),
            1: const pw.FlexColumnWidth(1.4),
          },
          data: [
            for (final l in lines)
              [
                '${l['product_code'] ?? '—'}\n${l['product_name']}',
                l['unit'],
                procurementNumber(l['ordered_quantity'], decimals: 3),
                if (!complete)
                  procurementNumber(l['previous_quantity'], decimals: 3),
                if (!complete)
                  procurementNumber(l['received_quantity'], decimals: 3),
                if (release)
                  procurementNumber(l['released_quantity'], decimals: 3),
                if (held) procurementNumber(l['held_quantity'], decimals: 3),
                procurementNumber(l['cumulative_quantity'], decimals: 3),
                if (!complete)
                  procurementNumber(l['shortage_quantity'], decimals: 3),
                if (!complete)
                  procurementNumber(l['excess_quantity'], decimals: 3),
                if (!complete)
                  procurementNumber(l['rejected_quantity'], decimals: 3),
              ],
          ],
        ),
        pw.SizedBox(height: 12),
        if (complete)
          pw.Text(
            t(
              '위 PO의 모든 원료가 발주 수량대로 입고되었습니다.',
              'All materials in this PO have been received in the ordered quantities.',
              'Tất cả nguyên liệu của PO đã được nhập đủ số lượng đặt.',
            ),
          ),
        if (!complete) ...[
          pw.Text(
            t(
              '미합격 수량에는 보류분이 포함될 수 있습니다. 보류분은 재검수·처분 후 부족분 이월을 판단합니다.',
              'Unaccepted quantities may include held stock. Resolve held stock before carrying shortages forward.',
              'Số chưa đạt có thể gồm hàng tạm giữ. Xử lý hàng tạm giữ trước khi chuyển thiếu hụt.',
            ),
          ),
          for (final l in lines)
            if ((l['reason']?.toString() ?? '').isNotEmpty)
              pw.Text(
                '${l['product_code'] ?? l['product_name']}: ${l['reason']}',
              ),
        ],
      ],
    ),
  );
  return doc.save();
}
