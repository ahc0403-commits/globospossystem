import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';

/// Writes worksheet XML straight into the ZIP deflater. Only the current row
/// and the compressed download artifact remain; no workbook cell matrix exists.
class StreamingXlsxWriter {
  StreamingXlsxWriter(this.sheetNames) {
    _part(
      '[Content_Types].xml',
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>${[for (var i = 0; i < sheetNames.length; i++) '<Override PartName="/xl/worksheets/sheet${i + 1}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'].join()}</Types>',
    );
    _part(
      '_rels/.rels',
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>',
    );
    _part(
      'xl/workbook.xml',
      '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>${[for (var i = 0; i < sheetNames.length; i++) '<sheet name="${_escape(sheetNames[i])}" sheetId="${i + 1}" r:id="rId${i + 1}"/>'].join()}</sheets></workbook>',
    );
    _part(
      'xl/styles.xml',
      '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs></styleSheet>',
    );
    _part(
      'xl/_rels/workbook.xml.rels',
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId${sheetNames.length + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>${[for (var i = 0; i < sheetNames.length; i++) '<Relationship Id="rId${i + 1}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet${i + 1}.xml"/>'].join()}</Relationships>',
    );
  }
  final List<String> sheetNames;
  final _output = OutputStream();
  final _entries =
      <({List<int> name, int offset, int size, int compressed, int crc})>[];
  Deflate? _deflate;
  List<int>? _name;
  int _offset = 0, _start = 0, _size = 0, _crc = 0, _row = 0, _sheet = 0;

  void _begin(String name) {
    _name = utf8.encode(name);
    _offset = _output.length;
    _size = 0;
    _crc = 0;
    _output.writeUint32(0x04034b50);
    _output.writeUint16(20);
    _output.writeUint16(8);
    _output.writeUint16(8);
    _output.writeUint16(0);
    _output.writeUint16(0);
    _output.writeUint32(0);
    _output.writeUint32(0);
    _output.writeUint32(0);
    _output.writeUint16(_name!.length);
    _output.writeUint16(0);
    _output.writeBytes(_name!);
    _start = _output.length;
    _deflate = Deflate(const [], flush: Deflate.NO_FLUSH, output: _output);
  }

  void _write(String value) {
    final bytes = utf8.encode(value);
    _crc = getCrc32(bytes, _crc);
    _size += bytes.length;
    _deflate!.addBytes(bytes, flush: Deflate.NO_FLUSH);
  }

  void _end() {
    _deflate!.addBytes(const [], flush: Deflate.FINISH);
    final compressed = _output.length - _start;
    _output.writeUint32(0x08074b50);
    _output.writeUint32(_crc);
    _output.writeUint32(compressed);
    _output.writeUint32(_size);
    _entries.add((
      name: _name!,
      offset: _offset,
      size: _size,
      compressed: compressed,
      crc: _crc,
    ));
    _deflate = null;
  }

  void _part(String name, String value) {
    _begin(name);
    _write(value);
    _end();
  }

  void beginSheet({List<double> columnWidths = const []}) {
    if (_deflate != null || _sheet >= sheetNames.length) {
      throw StateError('Invalid worksheet order');
    }
    _begin('xl/worksheets/sheet${++_sheet}.xml');
    _row = 0;
    final columns = columnWidths.isEmpty
        ? ''
        : '<cols>${[for (var i = 0; i < columnWidths.length; i++) '<col min="${i + 1}" max="${i + 1}" width="${columnWidths[i]}" customWidth="1"/>'].join()}</cols>';
    _write(
      '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">$columns<sheetData>',
    );
  }

  void addRow(Iterable<Object?> values) {
    var col = 0;
    final row = ++_row;
    final cells = values.map((v) {
      var n = ++col;
      var letters = '';
      while (n > 0) {
        n--;
        letters = String.fromCharCode(65 + n % 26) + letters;
        n ~/= 26;
      }
      final ref = '$letters$row';
      if (v is num && v.isFinite) return '<c r="$ref"><v>$v</v></c>';
      return '<c r="$ref" t="inlineStr"><is><t xml:space="preserve">${_escape(v?.toString() ?? '')}</t></is></c>';
    }).join();
    _write('<row r="$row">$cells</row>');
  }

  void endSheet() {
    _write('</sheetData></worksheet>');
    _end();
  }

  Uint8List finish() {
    if (_deflate != null || _sheet != sheetNames.length) {
      throw StateError('Incomplete XLSX worksheets');
    }
    final start = _output.length;
    for (final e in _entries) {
      _output.writeUint32(0x02014b50);
      _output.writeUint16(20);
      _output.writeUint16(20);
      _output.writeUint16(8);
      _output.writeUint16(8);
      _output.writeUint16(0);
      _output.writeUint16(0);
      _output.writeUint32(e.crc);
      _output.writeUint32(e.compressed);
      _output.writeUint32(e.size);
      _output.writeUint16(e.name.length);
      _output.writeUint16(0);
      _output.writeUint16(0);
      _output.writeUint16(0);
      _output.writeUint16(0);
      _output.writeUint32(0);
      _output.writeUint32(e.offset);
      _output.writeBytes(e.name);
    }
    final size = _output.length - start;
    _output.writeUint32(0x06054b50);
    _output.writeUint16(0);
    _output.writeUint16(0);
    _output.writeUint16(_entries.length);
    _output.writeUint16(_entries.length);
    _output.writeUint32(size);
    _output.writeUint32(start);
    _output.writeUint16(0);
    return Uint8List.fromList(_output.getBytes());
  }

  static String _escape(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');
}
