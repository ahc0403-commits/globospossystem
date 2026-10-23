import copy
import json
from decimal import Decimal
from pathlib import Path
import sys
import tempfile
import unittest
from zipfile import ZipFile, ZIP_DEFLATED
import xml.etree.ElementTree as ET

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
from misa_description_audit import POLICY, AUDIT_HEADERS, verify_record, permitted_cluster, verify_description_only_change, verify_source_manifest_descriptions

class DescriptionAuditTest(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.source=Path(self.temp.name)
        original='Mì · 🌶 Món cay · 매운 짬뽕'
        offset=len(original.split('🌶')[0].encode('utf-16-le'))//2
        self.record={'policy':POLICY,'invoice_sequence':'1','excel_row':'9',
            'source_system':'restaurant_pos','receipt_id':'receipt','order_item_id':'line','menu_item_id':'menu',
            'original_description':original,'export_description':original.replace('🌶',''),
            'removed_graphemes':[{'utf16_start':offset,'utf16_end':offset+2,'text':'🌶','code_points':['U+1F336']}]}
        sheets={'Hóa đơn GTGT':{8:{'K':'Description'},9:{'A':'1','K':original,'M':Decimal('1'),'N':Decimal('100000'),'O':Decimal('100000'),'P':Decimal('8'),'Q':Decimal('8000')}},
            'POS Ledger':{1:{'A':'version'},2:{'A':Decimal('3'),'D':'restaurant_pos','E':'receipt','G':'line','H':'menu','I':Decimal('1'),'J':Decimal('9'),'M':'original-line-hash'}},
            'Invoice Mapping':{1:{'A':'approval'},2:{'A':'immutable-profile'}},
            'Store Reconciliation':{1:{'A':'store','B':'gross'},2:{'A':'store','B':Decimal('108000')}},
            'Export Contract':{1:{'A':'format_version','B':'pos-sales-xlsx-v4'},2:{'A':'ledger_version','B':'3'},3:{'A':'source_gross','B':'108000.00'},4:{'A':'generation_id','B':'before'}}}
        self.write_book(self.source/'before.xlsx',sheets)
        updated=copy.deepcopy(sheets)
        updated['Hóa đơn GTGT'][9]['K']=self.record['export_description']
        updated['Export Contract'][5]={'A':'description_normalization_policy','B':POLICY}
        updated['Description Normalization']={1:dict(zip('ABCDEFGHIJ',AUDIT_HEADERS)),2:dict(zip('ABCDEFGHIJ',[json.dumps(self.record[k],ensure_ascii=False) if k=='removed_graphemes' else self.record[k] for k in AUDIT_HEADERS]))}
        self.write_book(self.source/'sample.xlsx',updated)
    @staticmethod
    def write_book(path,sheets):
        ns='http://schemas.openxmlformats.org/spreadsheetml/2006/main'
        rel='http://schemas.openxmlformats.org/officeDocument/2006/relationships'
        wb=ET.Element('{'+ns+'}workbook');entries=ET.SubElement(wb,'{'+ns+'}sheets');rels=ET.Element('Relationships')
        with ZipFile(path,'w',ZIP_DEFLATED) as archive:
            for index,(name,rows) in enumerate(sheets.items(),1):
                key='rId'+str(index)
                ET.SubElement(entries,'{'+ns+'}sheet',{'name':name,'{'+rel+'}id':key})
                ET.SubElement(rels,'Relationship',{'Id':key,'Target':'worksheets/sheet'+str(index)+'.xml'})
                root=ET.Element('{'+ns+'}worksheet');data=ET.SubElement(root,'{'+ns+'}sheetData')
                for rownum,cells in rows.items():
                    row=ET.SubElement(data,'{'+ns+'}row',{'r':str(rownum)})
                    for col,value in cells.items():
                        cell=ET.SubElement(row,'{'+ns+'}c',{'r':col+str(rownum),'t':'n' if isinstance(value,Decimal) else 'inlineStr'})
                        if isinstance(value,Decimal):ET.SubElement(cell,'{'+ns+'}v').text=str(value)
                        else:ET.SubElement(ET.SubElement(cell,'{'+ns+'}is'),'{'+ns+'}t').text=str(value)
                archive.writestr('xl/worksheets/sheet'+str(index)+'.xml',ET.tostring(root))
            archive.writestr('xl/workbook.xml',ET.tostring(wb))
            archive.writestr('xl/_rels/workbook.xml.rels',ET.tostring(rels))
    def test_source_manifest_name_is_authoritative(self):
        raw=self.record['original_description']
        self.assertEqual(verify_record(raw,self.record),raw.replace('🌶',''))
        with self.assertRaises(ValueError):verify_record(raw+' changed',self.record)
    def test_expected_description_cannot_change_real_words(self):
        r=copy.deepcopy(self.record);r['export_description']=r['export_description'].replace('cay','không cay')
        with self.assertRaises(ValueError):verify_record(r['original_description'],r)
    def test_audit_cannot_delete_digits_punctuation_or_text(self):
        for text in ['🌶123','🌶©','Món cay','🌶 Món cay','©','#1','𝄞','𠀀']:
            self.assertFalse(permitted_cluster(text),text)
    def test_valid_emoji_sequences(self):
        for text in ['🌶','🌶️','👩🏽‍🍳','👨‍👩‍👧‍👦','🇻🇳','1️⃣','©️','🌶‍']:
            self.assertTrue(permitted_cluster(text),text)
    def test_offsets_cannot_overlap_or_split_source(self):
        r=copy.deepcopy(self.record);r['removed_graphemes']*=2
        with self.assertRaises(ValueError):verify_record(r['original_description'],r)
        r=copy.deepcopy(self.record);r['removed_graphemes'][0]['utf16_end']-=1
        with self.assertRaises((ValueError,UnicodeError)):verify_record(r['original_description'],r)
    def test_policy_is_explicit(self):
        r=copy.deepcopy(self.record);r['policy']='arbitrary'
        with self.assertRaises(ValueError):verify_record(r['original_description'],r)
    def test_full_workbook_comparison_preserves_source(self):
        self.assertEqual(verify_description_only_change(self.source/'before.xlsx',self.source/'sample.xlsx')['description_changes'],1)
    def test_independent_source_manifest_keeps_original_names(self):
        manifest={'receipts':[{'sequence':1,'kind':'restaurant','receipt_id':'receipt','lines':[{'invoice_name':self.record['original_description']}]}]}
        saved=copy.deepcopy(manifest)
        verify_source_manifest_descriptions(manifest,self.source/'before.xlsx')
        self.assertEqual(verify_source_manifest_descriptions(manifest,self.source/'sample.xlsx')['source_description_lines_verified'],1)
        self.assertEqual(manifest,saved)
        manifest['receipts'][0]['lines'][0]['invoice_name']+=' changed'
        with self.assertRaises(ValueError):verify_source_manifest_descriptions(manifest,self.source/'sample.xlsx')
    def test_money_and_menu_identity_changes_are_rejected(self):
        for target,cell in [('xl/worksheets/sheet1.xml','O9'),('xl/worksheets/sheet2.xml','H2')]:
            with tempfile.TemporaryDirectory() as tmp:
                out=Path(tmp)/'changed.xlsx'
                with ZipFile(self.source/'sample.xlsx') as source,ZipFile(out,'w',ZIP_DEFLATED) as dest:
                    for entry in source.infolist():
                        data=source.read(entry.filename)
                        if entry.filename==target:
                            root=ET.fromstring(data)
                            node=root.find(".//{*}c[@r='"+cell+"']/{*}v")
                            if node is None:node=root.find(".//{*}c[@r='"+cell+"']/{*}is/{*}t")
                            node.text='999999';data=ET.tostring(root)
                        dest.writestr(entry,data)
                with self.assertRaises(ValueError):verify_description_only_change(self.source/'before.xlsx',out)

if __name__=='__main__':unittest.main()
