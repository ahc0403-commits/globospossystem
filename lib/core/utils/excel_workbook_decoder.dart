import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:excel/excel.dart';

/// Decodes XLSX files produced by both Excel and common server-side writers.
///
/// Some writers use absolute worksheet relationship targets such as
/// `/xl/worksheets/sheet1.xml`. `excel` 4.0.6 expects relative targets and
/// prepends `xl/`, so retry with only those relationship targets normalized.
Excel decodeExcelWorkbook(Uint8List bytes) {
  try {
    return Excel.decodeBytes(bytes);
  } catch (originalError, originalStackTrace) {
    try {
      final normalized = _normalizeAbsoluteWorksheetTargets(bytes);
      if (normalized != null) {
        return Excel.decodeBytes(normalized);
      }
    } catch (_) {
      // Preserve the original decoder error for callers and diagnostics.
    }
    Error.throwWithStackTrace(originalError, originalStackTrace);
  }
}

Uint8List? _normalizeAbsoluteWorksheetTargets(Uint8List bytes) {
  final archive = ZipDecoder().decodeBytes(bytes, verify: true);
  final relationship = archive.findFile('xl/_rels/workbook.xml.rels');
  if (relationship == null || !relationship.isFile) return null;

  relationship.decompress();
  final originalXml = utf8.decode(relationship.content as List<int>);
  final normalizedXml = originalXml
      .replaceAll('Target="/xl/worksheets/', 'Target="worksheets/')
      .replaceAll("Target='/xl/worksheets/", "Target='worksheets/");
  if (normalizedXml == originalXml) return null;

  final normalizedArchive = Archive();
  for (final file in archive.files) {
    if (!file.isFile) continue;
    file.decompress();
    final content = file.name == relationship.name
        ? Uint8List.fromList(utf8.encode(normalizedXml))
        : Uint8List.fromList(file.content as List<int>);
    normalizedArchive.addFile(ArchiveFile(file.name, content.length, content));
  }

  final encoded = ZipEncoder().encode(normalizedArchive);
  return encoded == null ? null : Uint8List.fromList(encoded);
}
