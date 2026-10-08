import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:excel/excel.dart';
import 'package:xml/xml.dart';

enum ExcelWorkbookDecodeFailure {
  invalidContainer,
  invalidXml,
  unsupportedNumberFormat,
  decodeFailed,
}

class ExcelWorkbookDecodeException implements Exception {
  const ExcelWorkbookDecodeException(
    this.failure, {
    required this.cause,
    required this.causeStackTrace,
  });

  final ExcelWorkbookDecodeFailure failure;
  final Object cause;
  final StackTrace causeStackTrace;

  @override
  String toString() => 'Excel workbook could not be read (${failure.name}).';
}

/// Reads XLSX without changing its cell values, formulas, or source file.
///
/// Inspect styles before decoding: excel 4.0.6 asserts on undefined formats in
/// debug, but silently reads them as numbers in release (including date IDs).
/// Only known numeric formats or explicitly defined formats may be repaired.
Excel decodeExcelWorkbook(Uint8List bytes) {
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes, verify: true);
    if (archive.findFile('xl/workbook.xml') == null) {
      throw const FormatException('Missing XLSX workbook');
    }
  } catch (error, stack) {
    throw ExcelWorkbookDecodeException(
      ExcelWorkbookDecodeFailure.invalidContainer,
      cause: error,
      causeStackTrace: stack,
    );
  }

  final changes = <String, List<int>>{};
  final styles = archive.findFile('xl/styles.xml');
  if (styles != null) {
    final xml = _readXml(styles);
    if (_normalizeNumberFormats(xml)) {
      changes[styles.name] = utf8.encode(xml.toXmlString());
    }
  }
  final relationships = archive.findFile('xl/_rels/workbook.xml.rels');
  if (relationships != null) {
    final xml = _readXml(relationships);
    var changed = false;
    for (final node in _elements(xml, 'Relationship')) {
      final target = node.getAttribute('Target');
      if (target != null && target.startsWith('/xl/worksheets/')) {
        node.setAttribute('Target', target.substring(4));
        changed = true;
      }
    }
    if (changed) changes[relationships.name] = utf8.encode(xml.toXmlString());
  }

  try {
    var input = bytes;
    if (changes.isNotEmpty) {
      final normalized = Archive();
      for (final file in archive.files) {
        final replacement = changes[file.name];
        normalized.addFile(
          replacement == null
              ? file
              : ArchiveFile(file.name, replacement.length, replacement),
        );
      }
      input = Uint8List.fromList(ZipEncoder().encode(normalized)!);
    }
    return Excel.decodeBytes(input);
  } catch (error, stack) {
    throw ExcelWorkbookDecodeException(
      error is XmlParserException
          ? ExcelWorkbookDecodeFailure.invalidXml
          : ExcelWorkbookDecodeFailure.decodeFailed,
      cause: error,
      causeStackTrace: stack,
    );
  }
}

XmlDocument _readXml(ArchiveFile file) {
  try {
    return XmlDocument.parse(utf8.decode(file.content as List<int>));
  } catch (error, stack) {
    throw ExcelWorkbookDecodeException(
      ExcelWorkbookDecodeFailure.invalidXml,
      cause: error,
      causeStackTrace: stack,
    );
  }
}

Iterable<XmlElement> _elements(XmlNode root, String name) => root.descendants
    .whereType<XmlElement>()
    .where((element) => element.name.local == name);

// Accounting formats omitted by excel 4.0.6. These are numeric, never dates.
const _accountingFormats = <int, String>{
  41: r'_(* #,##0_);_(* \(#,##0\);_(* "-"_);_(@_)',
  42: r'_("$"* #,##0_);_("$"* \(#,##0\);_("$"* "-"_);_(@_)',
  43: r'_(* #,##0.00_);_(* \(#,##0.00\);_(* "-"??_);_(@_)',
  44: r'_("$"* #,##0.00_);_("$"* \(#,##0.00\);_("$"* "-"??_);_(@_)',
};

bool _normalizeNumberFormats(XmlDocument xml) {
  try {
    final definitions = <int, XmlElement>{};
    var changed = false;
    for (final node in _elements(xml, 'numFmt').toList()) {
      // Differential styles have their own definitions, outside numFmts.
      if (node.parentElement?.name.local != 'numFmts') continue;
      final id = int.parse(node.getAttribute('numFmtId')!);
      final code = node.getAttribute('formatCode');
      if (id < 0 || code == null || code.isEmpty) {
        throw const FormatException('Invalid number format definition');
      }
      final previous = definitions[id];
      if (previous != null) {
        if (previous.getAttribute('formatCode') != code) {
          throw const FormatException('Conflicting number format definitions');
        }
        node.parent!.children.remove(node);
        changed = true;
      } else {
        definitions[id] = node;
      }
    }

    final references = xml.descendants
        .whereType<XmlElement>()
        .where(
          (node) =>
              node.name.local != 'numFmt' &&
              node.getAttribute('numFmtId') != null,
        )
        .toList();
    final referencedIds = {
      for (final node in references) int.parse(node.getAttribute('numFmtId')!),
    };
    final reserved = {...definitions.keys, ...referencedIds};
    var nextId = 164;
    int allocateId() {
      while (reserved.contains(nextId)) {
        nextId++;
      }
      final id = nextId++;
      reserved.add(id);
      return id;
    }

    final remapped = <int, int>{};
    for (final entry in definitions.entries) {
      if (entry.key >= 164) continue;
      final id = allocateId();
      remapped[entry.key] = id;
      entry.value.setAttribute('numFmtId', '$id');
      changed = true;
    }

    final supported = NumFormatMaintainer();
    for (final id in referencedIds) {
      if (definitions.containsKey(id) || supported.getByNumFmtId(id) != null) {
        continue;
      }
      final code = _accountingFormats[id];
      if (code == null) {
        throw const FormatException('Undefined number format');
      }
      var container = _elements(xml, 'numFmts').firstOrNull;
      if (container == null) {
        container = XmlElement(XmlName('numFmts', xml.rootElement.name.prefix));
        xml.rootElement.children.insert(0, container);
      }
      final newId = allocateId();
      remapped[id] = newId;
      container.children.add(
        XmlElement(XmlName('numFmt', container.name.prefix), [
          XmlAttribute(XmlName('numFmtId'), '$newId'),
          XmlAttribute(XmlName('formatCode'), code),
        ]),
      );
      changed = true;
    }
    for (final node in references) {
      final id = remapped[int.parse(node.getAttribute('numFmtId')!)];
      if (id != null) node.setAttribute('numFmtId', '$id');
    }
    if (changed) {
      for (final container in _elements(xml, 'numFmts')) {
        container.setAttribute(
          'count',
          '${container.childElements.where((node) => node.name.local == 'numFmt').length}',
        );
      }
    }
    return changed;
  } catch (error, stack) {
    throw ExcelWorkbookDecodeException(
      ExcelWorkbookDecodeFailure.unsupportedNumberFormat,
      cause: error,
      causeStackTrace: stack,
    );
  }
}
