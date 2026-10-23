#!/usr/bin/env python3
"""Independently verify that MISA Description edits delete only declared emoji.

Standard library only. Original source text and ledger hashes remain authoritative.
No customer values or monetary values are copied into error messages.
"""
import json
from bisect import bisect_right
from decimal import Decimal
from pathlib import Path
import posixpath
import xml.etree.ElementTree as ET
from zipfile import ZipFile

POLICY = 'misa-description-emoji-v1-unicode18'
DATA = json.loads((Path(__file__).parent/'data/misa_emoji_properties.json').read_text())['properties']
STARTS = {k:[r[0] for r in v] for k,v in DATA.items()}
AUDIT_HEADERS = ['policy', 'invoice_sequence', 'excel_row', 'source_system', 'receipt_id', 'order_item_id', 'menu_item_id', 'original_description', 'export_description', 'removed_graphemes']

def has(value, prop):
    index = bisect_right(STARTS[prop], value)-1
    return index >= 0 and value <= DATA[prop][index][1]

def ascii_base(v):
    return v in (0x23, 0x2A) or 0x30 <= v <= 0x39

def regional(v):
    return 0x1F1E6 <= v <= 0x1F1FF

def component(v):
    return has(v, 'Emoji_Component') or v == 0xFE0E

def permitted_cluster(text):
    values = list(map(ord, text))
    if not values:
        return False
    if len(values) == 2 and all(map(regional, values)):
        return True
    if ascii_base(values[0]):
        return 0x20E3 in values and all(v in (0xFE0E, 0xFE0F, 0x20E3) for v in values[1:])
    if not any(has(v, 'Emoji') and (has(v, 'Emoji_Presentation') or v >= 0x1F000 and has(v, 'Extended_Pictographic') or 0xFE0F in values or 0x200D in values) for v in values):
        return False
    i = 0
    while i < len(values):
        if not has(values[i], 'Emoji') or component(values[i]):
            return False
        i += 1
        while i < len(values) and component(values[i]) and not ascii_base(values[i]) and not regional(values[i]) and values[i] != 0x200D:
            i += 1
        if i < len(values):
            if values[i] != 0x200D:
                return False
            i += 1  # A trailing connector attached to a removed emoji is removed too.
    return True

def residual_emoji(text):
    return any(v in (0xFE0F, 0x200D, 0x20E3) or has(v, 'Emoji_Presentation') or v >= 0x1F000 and has(v, 'Emoji') and has(v, 'Extended_Pictographic') for v in map(ord, text))

def verify_record(original, record):
    if record.get('policy') != POLICY or record.get('original_description') != original:
        raise ValueError('Description audit policy/original mismatch')
    removals = record['removed_graphemes']
    if isinstance(removals, str):
        removals = json.loads(removals)
    if not isinstance(removals, list) or not removals:
        raise ValueError('Description audit has no removals')
    raw = original.encode('utf-16-le', errors='strict')
    cursor = 0
    output = bytearray()
    for removal in removals:
        start, end = removal['utf16_start'], removal['utf16_end']
        if not isinstance(start, int) or not isinstance(end, int) or not cursor <= start < end <= len(raw)//2:
            raise ValueError('Description audit offsets overlap or exceed source')
        cluster = raw[start*2:end*2].decode('utf-16-le', errors='strict')
        expected_points = [f'U+{ord(c):04X}' for c in cluster]
        if cluster != removal['text'] or removal['code_points'] != expected_points or not permitted_cluster(cluster):
            raise ValueError('Description audit deletes non-emoji source text')
        if end < len(raw)//2:
            tail = raw[end*2:].decode('utf-16-le', errors='strict')
            if component(ord(tail[0])) and not ascii_base(ord(tail[0])) and not regional(ord(tail[0])):
                raise ValueError('Description audit leaves an emoji component behind')
        output.extend(raw[cursor*2:start*2])
        cursor = end
    output.extend(raw[cursor*2:])
    normalized = output.decode('utf-16-le', errors='strict')
    if not normalized.strip() or residual_emoji(normalized) or normalized != record.get('export_description'):
        raise ValueError('Description audit result is empty, incomplete or altered')
    return normalized

NS = {'s': 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'}
REL = '{http://schemas.openxmlformats.org/officeDocument/2006/relationships}id'

def read_rows(file):
    with ZipFile(file) as archive:
        shared = []
        if 'xl/sharedStrings.xml' in archive.namelist():
            shared = [''.join(x.itertext()) for x in ET.fromstring(archive.read('xl/sharedStrings.xml'))]
        relations = {r.attrib['Id']:r.attrib['Target'] for r in ET.fromstring(archive.read('xl/_rels/workbook.xml.rels'))}
        sheets = {}
        for sheet in ET.fromstring(archive.read('xl/workbook.xml')).findall('s:sheets/s:sheet', NS):
            target = relations[sheet.attrib[REL]]
            target = target.lstrip('/') if target.startswith('/') else posixpath.normpath('xl/'+target)
            rows = {}
            for row in ET.fromstring(archive.read(target)).findall('s:sheetData/s:row', NS):
                cells = {}
                for cell in row:
                    ref = ''.join(filter(str.isalpha, cell.attrib['r']))
                    node = cell.find('s:v',NS)
                    value = node.text if node is not None and node.text else ''
                    kind = cell.attrib.get('t','n')
                    if kind == 's': value = shared[int(value)]
                    elif kind == 'inlineStr': value = ''.join(cell.find('s:is',NS).itertext())
                    elif value: value = Decimal(value)
                    cells[ref] = value
                rows[int(row.attrib['r'])] = cells
            sheets[sheet.attrib['name']] = rows
        return sheets

def audit_records(sheets):
    contract = {r['A']: r['B'] for r in sheets['Export Contract'].values()}
    policy = contract.get('description_normalization_policy')
    if policy not in (None, POLICY):
        raise ValueError('Unknown Description policy')
    audit = sheets.get('Description Normalization', {})
    columns = 'ABCDEFGHIJ'
    if audit and [audit.get(1, {}).get(c) for c in columns] != AUDIT_HEADERS:
        raise ValueError('Description audit header mismatch')
    if audit and policy != POLICY:
        raise ValueError('Description audit has no declared policy')
    records = {}
    for index, row in audit.items():
        if index == 1:
            continue
        record = dict(zip(AUDIT_HEADERS, (row[c] for c in columns)))
        target = int(record['excel_row'])
        if target in records:
            raise ValueError('Duplicate Description audit row')
        records[target] = record
    return policy, records

def verify_audit_identity(record, index, ledger, row):
    identity = ledger.get(index, {})
    for key, col in [('invoice_sequence', 'I'), ('source_system', 'D'),
                     ('receipt_id', 'E'), ('order_item_id', 'G'), ('menu_item_id', 'H')]:
        if str(record[key]) != str(identity.get(col, '')):
            raise ValueError(f'Description audit identity mismatch at row {index}')
    if (str(row.get('A')) != str(record['invoice_sequence']) or
            record['source_system'] != 'restaurant_pos'):
        raise ValueError(f'Description audit scope mismatch at row {index}')

def verify_description_only_change(before_file, after_file):
    before, after = read_rows(before_file), read_rows(after_file)
    if set(before) - {'Description Normalization'} != set(after) - {'Description Normalization'}:
        raise ValueError('Unexpected workbook sheet change')
    policy, records = audit_records(after)
    ledger = {int(row['J']):row for i,row in before['POS Ledger'].items() if i > 1}
    changes = 0
    for sheet, rows in before.items():
        if sheet == 'Description Normalization': continue
        if sheet == 'Export Contract':
            old = {r['A']:r['B'] for r in rows.values()}
            new = {r['A']:r['B'] for r in after[sheet].values()}
            new.pop('description_normalization_policy',None)
            old.pop('description_normalization_policy',None)
            old.pop('generation_id',None);new.pop('generation_id',None)
            if old != new: raise ValueError('Export Contract source/count/amount mismatch')
            continue
        if set(rows) != set(after[sheet]): raise ValueError(f'{sheet}: row count changed')
        for index, row in rows.items():
            updated = dict(after[sheet][index])
            if sheet == 'Hóa đơn GTGT' and index in records:
                record = records.pop(index)
                verify_audit_identity(record, index, ledger, row)
                if verify_record(row['K'],record) != updated.get('K'):
                    raise ValueError(f'Description mismatch at row {index}')
                updated['K'] = row['K'];changes += 1
            elif (sheet == 'Hóa đơn GTGT' and index > 8 and policy == POLICY and
                  ledger.get(index, {}).get('D') == 'restaurant_pos' and
                  residual_emoji(str(updated.get('K','')))):
                raise ValueError(f'Missing Description audit at row {index}')
            if row != updated: raise ValueError(f'{sheet}: unexpected data change at row {index}')
    if records: raise ValueError('Unbound Description audit rows')
    return {'policy':POLICY,'description_changes':changes,'all_other_cells_preserved':True,'source_ledger_hashes_preserved':True}

def verify_source_manifest_descriptions(manifest, workbook):
    """Additional Description guard; all other independent source checks stay in force.

    Uses the independent manifest's original invoice_name, never approval/name
    values taken from the uploaded workbook. The manifest is not modified.
    """
    sheets=read_rows(workbook)
    policy,records=audit_records(sheets)
    ledger={int(row['J']):row for i,row in sheets['POS Ledger'].items() if i>1}
    invoices={}
    for index,row in sheets['Hóa đơn GTGT'].items():
        if index>8:invoices.setdefault(str(row.get('A')),[]).append((index,row))
    receipts=manifest.get('receipts',[])
    if len(receipts)!=len(invoices):raise ValueError('Source receipt count differs')
    sequences=[str(receipt['sequence']) for receipt in receipts]
    if len(set(sequences))!=len(sequences) or set(sequences)!=set(invoices):
        raise ValueError('Source invoice sequences differ or are duplicated')
    count=0
    for receipt in receipts:
        sequence=str(receipt['sequence'])
        rows=invoices.get(sequence,[])
        lines=receipt.get('lines',[])
        if len(rows)!=len(lines):raise ValueError('Source line count differs')
        for line,(index,row) in zip(lines,rows):
            if str(ledger.get(index,{}).get('E'))!=str(receipt['receipt_id']):
                raise ValueError(f'Source receipt identity differs at row {index}')
            original=line['invoice_name']
            record=records.pop(index,None)
            if record:
                if policy!=POLICY or receipt.get('kind')=='photo':raise ValueError('Description policy scope differs')
                verify_audit_identity(record, index, ledger, row)
                expected=verify_record(original,record)
            else:
                expected=original
                if policy==POLICY and receipt.get('kind')!='photo' and residual_emoji(expected):
                    raise ValueError(f'Missing source Description normalization at row {index}')
            if str(row.get('K'))!=expected:raise ValueError(f'Source Description differs at row {index}')
            count+=1
    if records:raise ValueError('Unbound source Description audits')
    return {'source_description_lines_verified':count,'original_manifest_preserved':True}
