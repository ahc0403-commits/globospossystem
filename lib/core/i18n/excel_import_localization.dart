import '../../l10n/app_localizations.dart';
import '../utils/excel_workbook_decoder.dart';

String excelWorkbookDecodeMessage(
  AppLocalizations l10n,
  ExcelWorkbookDecodeException error,
) => switch (error.failure) {
  ExcelWorkbookDecodeFailure.invalidContainer =>
    l10n.excelImportInvalidContainer,
  ExcelWorkbookDecodeFailure.invalidXml => l10n.excelImportInvalidXml,
  ExcelWorkbookDecodeFailure.unsupportedNumberFormat =>
    l10n.excelImportUnsupportedNumberFormat,
  ExcelWorkbookDecodeFailure.decodeFailed => l10n.excelImportDecodeFailed,
};
