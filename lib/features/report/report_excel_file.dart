import 'dart:typed_data';

import 'package:file_saver/file_saver.dart';

typedef ReportExcelFileSaver =
    Future<void> Function({required String name, required Uint8List bytes});

Future<void> saveReportExcelFile({
  required String name,
  required Uint8List bytes,
}) async {
  await FileSaver.instance.saveFile(
    name: name,
    bytes: bytes,
    ext: 'xlsx',
    mimeType: MimeType.microsoftExcel,
  );
}
