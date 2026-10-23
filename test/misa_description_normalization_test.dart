import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/admin/misa_description_normalization.dart';
import 'package:globos_pos_system/features/admin/einvoice_misa_workbook.dart';
import 'fixtures/misa_email_delivery_fixture.dart';

String text(Data? c) => c?.value?.toString() ?? '';
const actualDescriptions = [
  'Mì · 🌶 Món cay · Mì/Cơm Tương Đen Xào Khô Cay',
  'Mì · 🌶 Món cay · Mì/Cơm Jjamppong Hải Sản Cay',
  'S · 🌶 Món cay · Tôm Chiên Sốt Cay',
  'Mì · 🌶 Món cay · Mì/Cơm Jjamppong Hải Sản Cay',
  'S · 🌶 Món cay · Gà Chiên Sốt Cay Tỏi',
];

void main() {
  test('removes actual rejected Description ornaments and is idempotent', () {
    for (final source in actualDescriptions) {
      final result = normalizeMisaDescription(source);
      expect(result.text, source.replaceAll('🌶', ''));
      expect(result.original, source);
      expect(result.removals, hasLength(1));
      expect(normalizeMisaDescription(result.text).text, result.text);
    }
  });
  test('removes whole emoji graphemes including selectors, flags and ZWJ', () {
    for (final emoji in [
      '🌶',
      '🌶️',
      '🌶︎',
      '👨‍👩‍👧‍👦',
      '👩🏽‍🍳',
      '🏳️‍🌈',
      '🇻🇳',
      '1️⃣',
      '#️⃣',
      '©️',
      '🌶‍',
    ]) {
      final result = normalizeMisaDescription('Canh $emoji chua');
      expect(result.text, 'Canh  chua', reason: emoji);
      expect(result.text.contains('\u200d'), isFalse);
      expect(result.text.contains('\ufe0f'), isFalse);
    }
  });
  test('preserves Vietnamese, Korean, punctuation and non-emoji non-BMP', () {
    const source = 'Cơm gà · 매운 짬뽕 (S/L) / + #1 * 10% © ® ™ ↔ 𠀀 𝄞 a\u0301';
    expect(normalizeMisaDescription(source).text, source);
    expect(normalizeMisaDescription(source).removals, isEmpty);
  });
  test('rejects empty output, orphan components and incompatible fields', () {
    for (final source in [
      '🌶️',
      ' \u200d ',
      'A\ufe0f',
      '1\ufe0f',
      'Canh\u000bchua',
      String.fromCharCode(0xD800),
      'A🌶\u0301B',
    ]) {
      expect(
        () => normalizeMisaDescription(source),
        throwsFormatException,
        reason: source,
      );
    }
  });
  test(
    'only Description changes; money, contacts, IDs and original hashes survive',
    () {
      final jobs = misaEmailDeliveryFixtureJobs();
      var counter = 0;
      for (final job in jobs) {
        for (final line in job['line_items_snapshot'] as List) {
          if (counter < actualDescriptions.length) {
            line['invoice_name_vi'] = actualDescriptions[counter++];
          }
        }
      }
      final original = jsonEncode(jobs);
      final control = (jsonDecode(original) as List)
          .cast<Map<String, dynamic>>();
      for (final job in control) {
        for (final line in job['line_items_snapshot'] as List) {
          line['invoice_name_vi'] = normalizeMisaDescription(
            line['invoice_name_vi'] as String,
          ).text;
        }
      }
      final audit = <Map<String, dynamic>>[];
      final bytes = buildMisaPendingInvoiceWorkbook(
        jobs,
        generationId: 'emoji-sample',
        descriptionNormalizations: audit,
      );
      final workbook = Excel.decodeBytes(bytes);
      final expected = Excel.decodeBytes(
        buildMisaPendingInvoiceWorkbook(control, generationId: 'emoji-sample'),
      );
      for (final sheet in [
        'Hóa đơn GTGT',
        'Store Reconciliation',
        'Invoice Mapping',
        'Email Delivery',
      ]) {
        expect(
          workbook[sheet].rows.map((r) => r.map(text).toList()).toList(),
          expected[sheet].rows.map((r) => r.map(text).toList()).toList(),
          reason: sheet,
        );
      }
      expect(audit, hasLength(5));
      expect(
        workbook['POS Ledger'].rows.skip(1).every((r) => text(r[0]) == '3'),
        isTrue,
      );
      final firstLine = (jobs.first['line_items_snapshot'] as List).first;
      expect(
        text(workbook['POS Ledger'].rows[1][12]),
        sha256.convert(utf8.encode(jsonEncode(firstLine))).toString(),
      );
      expect(jsonEncode(jobs), original);
      final sampleFolder = Platform.environment['MISA_DESCRIPTION_SAMPLE_DIR'];
      if (sampleFolder != null && sampleFolder.isNotEmpty) {
        final folder = Directory(sampleFolder)..createSync(recursive: true);
        File('${folder.path}/sample.xlsx').writeAsBytesSync(bytes);
        File('${folder.path}/source-jobs.json').writeAsStringSync(original);
        File(
          '${folder.path}/description-normalizations.json',
        ).writeAsStringSync(jsonEncode(audit));
      }
    },
  );
  test('Photo-only format and Description remain unchanged', () {
    final photo = <String, dynamic>{
      'receipt_id': 'photo',
      'source_system': 'photo_objet_moers',
      'created_at': '2026-10-22T01:00:00Z',
      'payment_method_snapshot': 'CASH',
      'line_items_snapshot': [
        {
          'display_name': 'Photo 🌶',
          'quantity': 1,
          'paying_amount_inc_tax': 108000,
        },
      ],
    };
    final workbook = Excel.decodeBytes(
      buildMisaPendingInvoiceWorkbook([photo]),
    );
    expect(text(workbook['Hóa đơn GTGT'].rows[8][10]), 'Photo 🌶');
    expect(workbook.tables.containsKey('Description Normalization'), isFalse);
    expect(
      workbook['Export Contract'].rows.any(
        (r) => text(r.first) == 'description_normalization_policy',
      ),
      isFalse,
    );
  });
  test(
    'empty normalized name reports the exact receipt, line, menu and field',
    () {
      final jobs = misaEmailDeliveryFixtureJobs();
      (jobs.first['line_items_snapshot'] as List).first['invoice_name_vi'] =
          '🌶';
      expect(
        () => buildMisaPendingInvoiceWorkbook(jobs),
        throwsA(
          isA<SalesExportValidationException>().having(
            (e) => e.issues.any(
              (i) =>
                  i.receiptId == 'email-fixture-0' &&
                  i.lineNumber == 1 &&
                  i.menuId == 'fixture-menu' &&
                  i.field == 'invoice_name_vi' &&
                  i.code == 'MISA_DESCRIPTION_EMPTY_AFTER_EMOJI_REMOVAL',
            ),
            'location',
            isTrue,
          ),
        ),
      );
    },
  );
}
