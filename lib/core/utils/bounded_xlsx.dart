import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml_events.dart';

const excelMaxCompressedBytes = 10 * 1024 * 1024;
const excelMaxExpandedBytes = 50 * 1024 * 1024;
const excelMaxCells = 200000;

class ExcelInputLimitException implements Exception {
  const ExcelInputLimitException(this.reason);
  final String reason;
  @override
  String toString() => 'Excel input exceeds its processing limit: $reason';
}

class _LimitedOutput extends OutputStream {
  _LimitedOutput(this.maximum) : super(size: 1024);
  final int maximum;
  void _reserve(int count) {
    if (length + count > maximum) {
      throw const ExcelInputLimitException('expanded bytes');
    }
  }

  @override
  void writeByte(int value) {
    _reserve(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, [int? len]) {
    _reserve(len ?? bytes.length);
    super.writeBytes(bytes, len);
  }

  @override
  void writeInputStream(InputStreamBase stream) {
    _reserve(stream.length);
    super.writeInputStream(stream);
  }
}

/// Decode through a bounded output, even if the ZIP declares a false size.
/// ZipDecoder(verify: true) eagerly inflates before callers can check budgets.
Archive readBoundedXlsxArchive(Uint8List bytes) {
  if (bytes.length > excelMaxCompressedBytes) {
    throw const ExcelInputLimitException('compressed bytes');
  }
  final decoder = ZipDecoder();
  decoder.decodeBytes(bytes, verify: false);
  final headers = decoder.directory.fileHeaders;
  if (headers.length > 2000) {
    throw const ExcelInputLimitException('ZIP entries');
  }
  var expanded = 0;
  var worksheets = 0;
  var cells = 0;
  var rectangularCells = 0;
  final archive = Archive();
  final names = <String>{};
  for (final header in headers) {
    final file = header.file!;
    if (!names.add(file.filename)) {
      throw const FormatException('Duplicate XLSX entry');
    }
    if ((file.flags & 1) != 0) {
      throw const FormatException('Encrypted XLSX is unsupported');
    }
    if ((file.uncompressedSize ?? 0) > excelMaxExpandedBytes - expanded) {
      throw const ExcelInputLimitException('declared expanded bytes');
    }
    final output = _LimitedOutput(excelMaxExpandedBytes - expanded);
    final input = InputStream(file.rawContent!.toUint8List());
    if (file.compressionMethod == ZipFile.zipCompressionDeflate) {
      Inflate.stream(input, output);
    } else if (file.compressionMethod == ZipFile.zipCompressionStore) {
      output.writeInputStream(input);
    } else {
      throw const FormatException('Unsupported XLSX compression');
    }
    final content = output.getBytes();
    expanded += content.length;
    if (content.length != header.uncompressedSize ||
        getCrc32(content) != file.crc32) {
      throw const FormatException('Invalid XLSX checksum or size');
    }
    if (file.filename.startsWith('xl/worksheets/') &&
        file.filename.endsWith('.xml')) {
      if (++worksheets > 10) throw const ExcelInputLimitException('worksheets');
      var maxRow = 0, maxColumn = 0;
      for (final event in parseEvents(
        utf8.decode(content),
        validateNesting: true,
      )) {
        if (event is! XmlStartElementEvent ||
            event.name.split(':').last != 'c') {
          continue;
        }
        if (++cells > excelMaxCells) {
          throw const ExcelInputLimitException('cells');
        }
        final ref = event.attributes
            .where((a) => a.name == 'r')
            .firstOrNull
            ?.value;
        final match = RegExp(r'^([A-Z]+)([1-9][0-9]*)$').firstMatch(ref ?? '');
        if (match == null) continue;
        final row = int.parse(match[2]!);
        var column = 0;
        for (final c in match[1]!.codeUnits) {
          column = column * 26 + c - 64;
        }
        if (row > maxRow) maxRow = row;
        if (column > maxColumn) maxColumn = column;
        if (maxRow * maxColumn + rectangularCells > excelMaxCells) {
          throw const ExcelInputLimitException('sparse sheet extent');
        }
      }
      rectangularCells += maxRow * maxColumn;
    }
    archive.addFile(ArchiveFile(file.filename, content.length, content));
  }
  if (archive.findFile('xl/workbook.xml') == null) {
    throw const FormatException('Missing XLSX workbook');
  }
  return archive;
}
