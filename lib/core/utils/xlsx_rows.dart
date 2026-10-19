import 'dart:convert';
import 'dart:typed_data';

import 'package:xml/xml.dart';
import 'package:xml/xml_events.dart';

import 'bounded_xlsx.dart';
import 'excel_workbook_decoder.dart';

/// Values only, one row at a time; no Excel objects or dense workbook matrix.
Iterable<({String name, Iterable<List<Object?>> rows})> readXlsxRows(
  Uint8List bytes,
) sync* {
  final archive = readBoundedXlsxArchive(bytes);
  validateExcelArchiveFormats(archive);
  String text(String name) =>
      utf8.decode(archive.findFile(name)!.content as List<int>);
  final strings = <String>[];
  if (archive.findFile('xl/sharedStrings.xml') != null) {
    StringBuffer? value;
    var inText = false;
    for (final event in parseEvents(
      text('xl/sharedStrings.xml'),
      validateNesting: true,
    )) {
      if (event is XmlStartElementEvent) {
        final name = event.name.split(':').last;
        if (name == 'si') {
          value = StringBuffer();
          if (event.isSelfClosing) strings.add('');
        }
        if (name == 't') inText = true;
      } else if (event is XmlTextEvent && inText) {
        value?.write(event.value);
        if ((value?.length ?? 0) > 1024 * 1024) {
          throw const ExcelInputLimitException('cell text');
        }
      } else if (event is XmlEndElementEvent) {
        final name = event.name.split(':').last;
        if (name == 't') inText = false;
        if (name == 'si') {
          strings.add(value?.toString() ?? '');
          value = null;
        }
      }
    }
  }
  final timeStyles = <int>{};
  final dateTimeStyles = <int>{};
  if (archive.findFile('xl/styles.xml') != null) {
    final styles = XmlDocument.parse(text('xl/styles.xml'));
    final custom = <int, String>{
      for (final n in styles.descendants.whereType<XmlElement>().where(
        (n) => n.name.local == 'numFmt',
      ))
        int.parse(n.getAttribute('numFmtId')!):
            n.getAttribute('formatCode') ?? '',
    };
    final xfs = styles.descendants
        .whereType<XmlElement>()
        .where((n) => n.name.local == 'cellXfs')
        .firstOrNull;
    var index = 0;
    for (final xf in xfs?.childElements ?? <XmlElement>[]) {
      final id = int.tryParse(xf.getAttribute('numFmtId') ?? '') ?? 0;
      if (id == 22 ||
          (RegExp(r'[yYdD]').hasMatch(custom[id] ?? '') &&
              RegExp(r'[hH]').hasMatch(custom[id] ?? ''))) {
        dateTimeStyles.add(index);
      }
      if ({18, 19, 20, 21, 45, 46, 47}.contains(id) ||
          RegExp(r'[hH].*[mM]').hasMatch(custom[id] ?? '')) {
        timeStyles.add(index);
      }
      index++;
    }
  }
  final relationships = XmlDocument.parse(text('xl/_rels/workbook.xml.rels'));
  final targets = <String, String>{
    for (final n in relationships.descendants.whereType<XmlElement>().where(
      (n) => n.name.local == 'Relationship',
    ))
      n.getAttribute('Id')!: n.getAttribute('Target')!,
  };
  final workbook = XmlDocument.parse(text('xl/workbook.xml'));
  for (final sheet in workbook.descendants.whereType<XmlElement>().where(
    (n) => n.name.local == 'sheet',
  )) {
    final relationship = sheet.attributes
        .where((a) => a.name.local == 'id')
        .firstOrNull
        ?.value;
    final target = targets[relationship];
    if (target == null) continue;
    final path = target.startsWith('/') ? target.substring(1) : 'xl/$target';
    if (!path.startsWith('xl/worksheets/') || archive.findFile(path) == null) {
      throw const FormatException('Invalid XLSX worksheet target');
    }
    yield (
      name: sheet.getAttribute('name') ?? '',
      rows: _rows(text(path), strings, timeStyles, dateTimeStyles),
    );
  }
}

Iterable<List<Object?>> _rows(
  String xml,
  List<String> strings,
  Set<int> timeStyles,
  Set<int> dateTimeStyles,
) sync* {
  var row = <Object?>[];
  var sourceRow = 0;
  var column = 0;
  var style = 0;
  var type = '';
  var capture = false;
  var formula = false;
  var value = StringBuffer();
  for (final event in parseEvents(xml, validateNesting: true)) {
    if (event is XmlStartElementEvent) {
      final name = event.name.split(':').last;
      String? attr(String key) =>
          event.attributes.where((a) => a.name == key).firstOrNull?.value;
      if (name == 'row') {
        final next = int.tryParse(attr('r') ?? '') ?? sourceRow + 1;
        while (++sourceRow < next) {
          yield const [];
        }
        row = [];
        if (event.isSelfClosing) yield const [];
      } else if (name == 'c') {
        final ref = attr('r') ?? '';
        column = 0;
        for (final c in ref.codeUnits.takeWhile((c) => c >= 65 && c <= 90)) {
          column = column * 26 + c - 64;
        }
        column = column == 0 ? row.length : column - 1;
        style = int.tryParse(attr('s') ?? '') ?? 0;
        type = attr('t') ?? '';
        value = StringBuffer();
        formula = false;
        if (event.isSelfClosing) {
          while (row.length <= column) {
            row.add(null);
          }
        }
      } else if (name == 'v' || name == 't') {
        capture = true;
      } else if (name == 'f') {
        formula = true;
      }
    } else if (event is XmlTextEvent && capture) {
      value.write(event.value);
    } else if (event is XmlEndElementEvent) {
      final name = event.name.split(':').last;
      if (name == 'v' || name == 't') capture = false;
      if (name == 'c') {
        final raw = value.toString();
        Object? result = raw;
        if (type == 's') {
          final index = int.parse(raw);
          if (index < 0 || index >= strings.length) {
            throw const FormatException('Invalid shared string');
          }
          result = strings[index];
        } else if (type.isEmpty || type == 'n') {
          result = num.tryParse(raw) ?? raw;
          if (result is num && dateTimeStyles.contains(style)) {
            // Excel 1900 date system, matching the former workbook decoder.
            result = DateTime.utc(1899, 12, 30)
                .add(Duration(milliseconds: (result * 86400000).round()))
                .toIso8601String()
                .replaceFirst('T', ' ')
                .substring(0, 19);
          } else if (result is num && timeStyles.contains(style)) {
            final seconds = ((result % 1) * 86400).round() % 86400;
            result =
                '${(seconds ~/ 3600).toString().padLeft(2, '0')}:${((seconds ~/ 60) % 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
          }
        }
        if (formula) {
          throw const FormatException(
            'Photo import requires saved values, not formulas',
          );
        }
        while (row.length <= column) {
          row.add(null);
        }
        row[column] = result;
      } else if (name == 'row') {
        yield row;
      }
    }
  }
}
