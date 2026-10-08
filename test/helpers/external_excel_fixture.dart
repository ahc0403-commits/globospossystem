import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

class ExternalExcelCell {
  const ExternalExcelCell(this.value, this.style);

  final Object? value;
  final int style;
}

class ExternalExcelFormula {
  const ExternalExcelFormula(this.formula, this.cachedValue);

  final String formula;
  final num cachedValue;
}

// Hand-written OOXML, independent of excel's writer. No real business data.
Uint8List externalExcelFixture({
  String sheetName = 'Sheet1',
  List<List<Object?>> rows = const [
    ['Code', 'Price'],
    ['00123', 537037],
  ],
  int formatId = 43,
  bool explicitFormat = true,
  String formatCode = '#,##0.00;(#,##0.00)',
  bool duplicateFormat = false,
  bool conflictingFormat = false,
  bool absoluteTarget = false,
  bool malformedStyles = false,
}) {
  String escape(Object value) => value
      .toString()
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');
  String column(int index) {
    var result = '';
    for (var n = index + 1; n > 0; n = (n - 1) ~/ 26) {
      result = String.fromCharCode(65 + (n - 1) % 26) + result;
    }
    return result;
  }

  final rowXml = <String>[];
  for (var r = 0; r < rows.length; r++) {
    final cells = <String>[];
    for (var c = 0; c < rows[r].length; c++) {
      final input = rows[r][c];
      final value = input is ExternalExcelCell ? input.value : input;
      if (value == null) continue;
      final style = input is ExternalExcelCell
          ? input.style
          : value is num || value is ExternalExcelFormula
          ? 1
          : 0;
      final ref = '${column(c)}${r + 1}';
      final prefix = '<c r="$ref" s="$style"';
      if (value is ExternalExcelFormula) {
        cells.add(
          '$prefix><f>${escape(value.formula)}</f><v>${value.cachedValue}</v></c>',
        );
      } else if (value is num) {
        cells.add('$prefix><v>$value</v></c>');
      } else if (value is bool) {
        cells.add('$prefix t="b"><v>${value ? 1 : 0}</v></c>');
      } else {
        cells.add('$prefix t="inlineStr"><is><t>${escape(value)}</t></is></c>');
      }
    }
    rowXml.add('<row r="${r + 1}">${cells.join()}</row>');
  }
  final extraDefinition = !duplicateFormat && !conflictingFormat
      ? ''
      : '<numFmt numFmtId="$formatId" formatCode="${conflictingFormat ? 'yyyy-mm-dd' : escape(formatCode)}"/>';
  final styles = malformedStyles
      ? '<styleSheet><broken'
      : '''<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
<numFmts count="${(explicitFormat ? 2 : 1) + (extraDefinition.isEmpty ? 0 : 1)}">
${explicitFormat ? '<numFmt numFmtId="$formatId" formatCode="${escape(formatCode)}"/>' : ''}
<numFmt numFmtId="164" formatCode="0.0000"/>$extraDefinition</numFmts>
<fonts count="1"><font><sz val="11"/><name val="Arial"/></font></fonts>
<fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>
<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
<cellStyleXfs count="1"><xf numFmtId="$formatId" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
<cellXfs count="6">
<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>
<xf numFmtId="$formatId" fontId="0" fillId="0" borderId="0" xfId="0"/>
<xf numFmtId="14" fontId="0" fillId="0" borderId="0" xfId="0"/>
<xf numFmtId="21" fontId="0" fillId="0" borderId="0" xfId="0"/>
<xf numFmtId="9" fontId="0" fillId="0" borderId="0" xfId="0"/>
<xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0"/>
</cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
</styleSheet>''';
  final parts = {
    '[Content_Types].xml':
        '''<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>''',
    '_rels/.rels':
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>',
    'xl/workbook.xml':
        '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="${escape(sheetName)}" sheetId="1" r:id="rId1"/></sheets></workbook>',
    'xl/_rels/workbook.xml.rels':
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="${absoluteTarget ? '/xl/' : ''}worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>',
    'xl/styles.xml': styles,
    'xl/worksheets/sheet1.xml':
        '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>${rowXml.join()}</sheetData></worksheet>',
  };
  final archive = Archive();
  for (final entry in parts.entries) {
    final content = utf8.encode(entry.value);
    archive.addFile(ArchiveFile(entry.key, content.length, content));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}
