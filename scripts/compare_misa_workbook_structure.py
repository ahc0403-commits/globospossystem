#!/usr/bin/env python3
"""Compare actual MISA workbooks without reading buyer rows into the report.

Uses only the standard library. Input workbooks remain local and unchanged.
Sales-dependent row counts, dates and amounts are reported, not treated as
structural changes. A changed import schema or missing audit sheet fails.
"""
import argparse
import json
from pathlib import Path
import posixpath
import xml.etree.ElementTree as ET
from zipfile import ZipFile

NS = {'s': 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'}
REL = '{http://schemas.openxmlformats.org/officeDocument/2006/relationships}id'
CORE = {'Hóa đơn GTGT': 8, 'POS Ledger': 1, 'Invoice Mapping': 1, 'Export Contract': 1}


def inspect(path):
    with ZipFile(path) as archive:
        strings = []
        if 'xl/sharedStrings.xml' in archive.namelist():
            strings = [''.join(n.itertext()) for n in ET.fromstring(archive.read('xl/sharedStrings.xml'))]
        rels = {r.attrib['Id']: r.attrib['Target'] for r in ET.fromstring(archive.read('xl/_rels/workbook.xml.rels'))}
        sheets = {}
        for entry in ET.fromstring(archive.read('xl/workbook.xml')).findall('s:sheets/s:sheet', NS):
            target = rels[entry.attrib[REL]]
            target = target.lstrip('/') if target.startswith('/') else posixpath.normpath('xl/' + target)
            xml = ET.fromstring(archive.read(target))
            rows = xml.findall('s:sheetData/s:row', NS)
            def value(cell):
                node = cell.find('s:v', NS)
                raw = node.text if node is not None else ''
                if cell.attrib.get('t') == 's':
                    return strings[int(raw)]
                if cell.attrib.get('t') == 'inlineStr':
                    return ''.join(cell.find('s:is', NS).itertext())
                return raw or ''
            by_row = {int(r.attrib['r']): r for r in rows}
            name = entry.attrib['name']
            header_row = CORE.get(name, 1)
            header = [value(c) for c in by_row.get(header_row, [])]
            columns = max((len(r) for r in rows), default=0)
            info = {'columns': columns, 'header_row': header_row, 'header': header,
                    'rows': len(rows), 'merged_cells': [c.attrib['ref'] for c in xml.findall('s:mergeCells/s:mergeCell', NS)],
                    'column_layout': [c.attrib for c in xml.findall('s:cols/s:col', NS)]}
            if name == 'Hóa đơn GTGT':
                info['instructions'] = [[value(c) for c in by_row.get(i, [])] for i in range(1, 8)]
                data = [r for r in rows if int(r.attrib['r']) > 8]
                invoice_ids = set()
                invalid = 0
                for row in data:
                    cells = {''.join(filter(str.isalpha, c.attrib['r'])): c for c in row}
                    sequence = cells.get('A')
                    if sequence is not None:
                        invoice_ids.add(value(sequence))
                    # MISA invoice sequences must remain text, numeric columns numeric.
                    invalid += sequence is None or sequence.attrib.get('t') not in ('s', 'inlineStr')
                    for col in ('M', 'N', 'O', 'P', 'Q'):
                        cell = cells.get(col)
                        invalid += cell is None or cell.attrib.get('t') in ('s', 'inlineStr')
                info['invoice_count'] = len(invoice_ids)
                info['data_rows'] = len(data)
                info['invalid_data_types'] = invalid
            if name == 'Export Contract':
                info['contract'] = {value(r[0]): value(r[1]) for r in rows if len(r) >= 2}
                info['contract_keys'] = [value(r[0]) for r in rows if len(r) >= 2]
            sheets[name] = info
    return sheets


def compare(before, after):
    differences = []
    if set(before) != set(after):
        differences.append('worksheet_names')
    for name in CORE:
        if name not in before or name not in after:
            differences.append(f'{name}:missing_sheet')
            continue
        for key in ('columns', 'header_row', 'header', 'merged_cells', 'column_layout'):
            if before[name][key] != after[name][key]:
                differences.append(f'{name}:{key}')
    if before.get('Hóa đơn GTGT', {}).get('instructions') != after.get('Hóa đơn GTGT', {}).get('instructions'):
        differences.append('Hóa đơn GTGT:instructions')
    for key in ('contract_keys',):
        if before.get('Export Contract', {}).get(key) != after.get('Export Contract', {}).get(key):
            differences.append(f'Export Contract:{key}')
    for key in ('format_version', 'ledger_version'):
        if before.get('Export Contract', {}).get('contract', {}).get(key) != after.get('Export Contract', {}).get('contract', {}).get(key):
            differences.append(f'Export Contract:{key}')
    for label, sheets in [('before', before), ('after', after)]:
        if sheets.get('Hóa đơn GTGT', {}).get('invalid_data_types'):
            differences.append(f'{label}:invalid_data_types')
    return differences


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('before', type=Path)
    parser.add_argument('after', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--allow-description-normalization', action='store_true',
                        help='Require an exact source-data comparison allowing only audited emoji deletion')
    parser.add_argument('--source-manifest', type=Path, help='Independent manifest retaining original invoice_name values')
    args = parser.parse_args()
    if args.source_manifest and not args.allow_description_normalization:
        parser.error('--source-manifest requires --allow-description-normalization')
    before, after = inspect(args.before), inspect(args.after)
    differences = compare(before, after)
    description_audit = None
    if args.allow_description_normalization:
        from misa_description_audit import verify_description_only_change, verify_source_manifest_descriptions
        try:
            description_audit = verify_description_only_change(args.before, args.after)
            if args.source_manifest:
                original_manifest = json.loads(args.source_manifest.read_text())
                verify_source_manifest_descriptions(original_manifest, args.before)
                description_audit.update(verify_source_manifest_descriptions(original_manifest, args.after))
            differences = [v for v in differences if v not in ('worksheet_names', 'Export Contract:contract_keys')]
        except (ValueError, KeyError, UnicodeError, TypeError):
            differences.append('description_normalization:source_or_audit_mismatch')
    report = {'structure_matches': not differences, 'differences': differences,
              'before': {k: {field: val for field, val in v.items() if field in ('columns', 'rows', 'invoice_count', 'data_rows', 'invalid_data_types', 'contract')} for k, v in before.items()},
              'after': {k: {field: val for field, val in v.items() if field in ('columns', 'rows', 'invoice_count', 'data_rows', 'invalid_data_types', 'contract')} for k, v in after.items()}}
    if description_audit is not None:
        report['description_normalization'] = description_audit
    output = json.dumps(report, ensure_ascii=False, indent=2) + '\n'
    if args.output:
        args.output.write_text(output)
    print(output)
    raise SystemExit(bool(differences))


if __name__ == '__main__':
    main()
