import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/i18n/excel_import_localization.dart';
import 'package:globos_pos_system/core/utils/excel_workbook_decoder.dart';
import 'package:globos_pos_system/l10n/app_localizations_en.dart';
import 'package:globos_pos_system/l10n/app_localizations_ko.dart';
import 'package:globos_pos_system/l10n/app_localizations_vi.dart';

import 'helpers/external_excel_fixture.dart';

void main() {
  test(
    'repairs external format 43 and absolute targets without changing input',
    () {
      final bytes = externalExcelFixture(absoluteTarget: true);
      final before = Uint8List.fromList(bytes);
      expect(() => Excel.decodeBytes(bytes), throwsException);

      final sheet = decodeExcelWorkbook(bytes).tables['Sheet1']!;
      expect(sheet.rows[1][0]!.value, TextCellValue('00123'));
      expect(sheet.rows[1][1]!.value, const IntCellValue(537037));
      expect(
        sheet.rows[1][1]!.cellStyle!.numberFormat.formatCode,
        '#,##0.00;(#,##0.00)',
      );
      expect(bytes, orderedEquals(before));
    },
  );

  for (final id in [41, 42, 43, 44]) {
    test(
      'reads undefined accounting format $id with original numeric values',
      () {
        final sheet = decodeExcelWorkbook(
          externalExcelFixture(
            formatId: id,
            explicitFormat: false,
            rows: const [
              [0, -537037, 12.3456],
            ],
          ),
        ).tables['Sheet1']!;
        expect(sheet.rows[0].map((cell) => cell!.value), [
          const IntCellValue(0),
          const IntCellValue(-537037),
          const DoubleCellValue(12.3456),
        ]);
      },
    );
  }

  test('preserves dates, times, percentages, decimals, and formula text', () {
    final serial = DateTime.utc(
      2026,
      10,
      8,
    ).difference(DateTime.utc(1899, 12, 30)).inDays;
    final sheet = decodeExcelWorkbook(
      externalExcelFixture(
        rows: [
          [
            537037,
            ExternalExcelCell(serial, 2),
            const ExternalExcelCell(0.5, 3),
            const ExternalExcelCell(0.08, 4),
            const ExternalExcelCell(12.3456, 5),
            const ExternalExcelFormula('A1*8%', 42962.96),
          ],
        ],
      ),
    ).tables['Sheet1']!;
    expect(
      sheet.rows[0][1]!.value,
      const DateCellValue(year: 2026, month: 10, day: 8),
    );
    expect(sheet.rows[0][2]!.value, const TimeCellValue(hour: 12));
    expect(sheet.rows[0][3]!.value, const DoubleCellValue(0.08));
    expect(sheet.rows[0][4]!.value, const DoubleCellValue(12.3456));
    expect(sheet.rows[0][4]!.cellStyle!.numberFormat.formatCode, '0.0000');
    expect(sheet.rows[0][5]!.value, const FormulaCellValue('A1*8%'));
  });

  test(
    'remaps explicit low date formats without converting them to numbers',
    () {
      final sheet = decodeExcelWorkbook(
        externalExcelFixture(
          formatId: 14,
          formatCode: 'yyyy-mm-dd',
          rows: const [
            [45292],
          ],
        ),
      ).tables['Sheet1']!;
      expect(
        sheet.rows[0][0]!.value,
        const DateCellValue(year: 2024, month: 1, day: 1),
      );
    },
  );

  test(
    'deduplicates equal definitions but refuses conflicting definitions',
    () {
      expect(
        decodeExcelWorkbook(
          externalExcelFixture(duplicateFormat: true),
        ).tables['Sheet1']!.rows[1][1]!.value,
        const IntCellValue(537037),
      );
      expect(
        () =>
            decodeExcelWorkbook(externalExcelFixture(conflictingFormat: true)),
        throwsA(
          isA<ExcelWorkbookDecodeException>().having(
            (error) => error.failure,
            'failure',
            ExcelWorkbookDecodeFailure.unsupportedNumberFormat,
          ),
        ),
      );
    },
  );

  test('refuses undefined regional date formats in debug and release', () {
    expect(
      () => decodeExcelWorkbook(
        externalExcelFixture(formatId: 55, explicitFormat: false),
      ),
      throwsA(
        isA<ExcelWorkbookDecodeException>().having(
          (error) => error.failure,
          'failure',
          ExcelWorkbookDecodeFailure.unsupportedNumberFormat,
        ),
      ),
    );
  });

  test('distinguishes invalid containers from malformed XML', () {
    expect(
      () => decodeExcelWorkbook(Uint8List.fromList([1, 2, 3])),
      throwsA(
        isA<ExcelWorkbookDecodeException>().having(
          (error) => error.failure,
          'failure',
          ExcelWorkbookDecodeFailure.invalidContainer,
        ),
      ),
    );
    expect(
      () => decodeExcelWorkbook(externalExcelFixture(malformedStyles: true)),
      throwsA(
        isA<ExcelWorkbookDecodeException>().having(
          (error) => error.failure,
          'failure',
          ExcelWorkbookDecodeFailure.invalidXml,
        ),
      ),
    );
  });

  test('supported files still decode normally', () {
    final bytes = externalExcelFixture(formatId: 3, explicitFormat: false);
    expect(
      decodeExcelWorkbook(bytes).tables['Sheet1']!.rows[1][1]!.value,
      Excel.decodeBytes(bytes).tables['Sheet1']!.rows[1][1]!.value,
    );
  });

  test(
    'decoder failures have safe Korean, English, and Vietnamese messages',
    () {
      const error = ExcelWorkbookDecodeException(
        ExcelWorkbookDecodeFailure.unsupportedNumberFormat,
        cause: 'private file contents',
        causeStackTrace: StackTrace.empty,
      );
      final messages = [
        excelWorkbookDecodeMessage(AppLocalizationsKo(), error),
        excelWorkbookDecodeMessage(AppLocalizationsEn(), error),
        excelWorkbookDecodeMessage(AppLocalizationsVi(), error),
      ];
      expect(messages[0], contains('셀 서식'));
      expect(messages[1], contains('cell formats'));
      expect(messages[2], contains('định dạng ô'));
      expect(messages.every((message) => !message.contains('private')), isTrue);
    },
  );
}
