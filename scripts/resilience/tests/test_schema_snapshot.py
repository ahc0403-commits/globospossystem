import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

TOOLS=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('schema_snapshot',TOOLS/'schema_snapshot.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
spec2=importlib.util.spec_from_file_location('schema_fixture',TOOLS/'integration_schema_snapshot.py')
fixture=importlib.util.module_from_spec(spec2);spec2.loader.exec_module(fixture)


class SchemaSnapshotTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.area=Path(self.tmp.name)
        detail={'owner':'postgres','acl':None}
        self.row={'kind':'schema','ident':'public','meta':detail,
                  'sha256':m.runtime.digest(m.runtime.pg_jsonb(detail).encode())}
        self.manifest={'projectRef':m.PROJECTS['pos'],'scope':sorted(m.SCOPES['pos']),
                       'objects':[{k:self.row[k] for k in ['kind','ident','sha256']}]}
        self.write('pos-manifest.json',self.manifest)
        self.write('pos-schema-0.json',[self.row])

    def write(self,name,value):
        p=self.area/name;p.write_text(json.dumps(value));p.chmod(0o600);return p

    def test_complete_private_source_is_accepted_without_database_access(self):
        manifest,rows=m.load('pos',self.area)
        self.assertEqual(rows,[self.row]);self.assertEqual(manifest['projectRef'],m.PROJECTS['pos'])

    def test_body_tampering_is_rejected_even_when_manifest_identity_matches(self):
        row=copy.deepcopy(self.row);row['meta']['owner']='another-owner'
        self.write('pos-schema-0.json',[row])
        with self.assertRaisesRegex(ValueError,'body/hash'):m.load('pos',self.area)

    def test_missing_and_duplicate_chunks_never_form_a_complete_snapshot(self):
        self.write('pos-schema-0.json',[])
        with self.assertRaisesRegex(ValueError,'Incomplete'):m.load('pos',self.area)
        self.write('pos-schema-0.json',[self.row]);self.write('pos-schema-1.json',[self.row])
        with self.assertRaisesRegex(ValueError,'Duplicate'):m.load('pos',self.area)

    def test_project_and_schema_scope_cannot_be_exchanged(self):
        for change in [{'projectRef':m.PROJECTS['office']},{'scope':['public']},
                       {'scope':[*m.SCOPES['pos'],'unexpected_schema']}]:
            self.write('pos-manifest.json',{**self.manifest,**change})
            with self.assertRaisesRegex(ValueError,'project/scope'):m.load('pos',self.area)

    def test_world_readable_metadata_and_symlinks_are_rejected(self):
        p=self.area/'pos-schema-0.json';p.chmod(0o644)
        with self.assertRaisesRegex(ValueError,'mode-600'):m.load('pos',self.area)
        p.chmod(0o600);original=self.area/'original.json';p.rename(original);p.symlink_to(original)
        with self.assertRaisesRegex(ValueError,'regular file'):m.load('pos',self.area)

    def test_object_and_input_privacy_bounds_are_checked_before_restore(self):
        self.write('pos-manifest.json',{**self.manifest,'objects':self.manifest['objects']*20001})
        with self.assertRaisesRegex(ValueError,'bound'):m.load('pos',self.area)
        self.write('pos-manifest.json',self.manifest);self.area.chmod(0o755)
        try:
            with self.assertRaisesRegex(ValueError,'private'):m.load('pos',self.area)
        finally:self.area.chmod(0o700)

    def test_unknown_schemas_and_unsupported_objects_cannot_be_silently_omitted(self):
        guards={'schemaInventory':sorted(m.SCOPES['pos']),
                **{key:0 for key in ['unsupportedRelations','unsupportedTypes','nonViewRules',
                 'customAggregates','customCollations','schemaPublications','otherLanguages','ordinaryInheritance']}}
        self.write('pos-inventory-guards.json',guards)
        m.inventory_guards('pos',self.area)
        for change in [{'schemaInventory':[*guards['schemaInventory'],'new_unreviewed_schema']},
                       {'unsupportedTypes':1},{'otherLanguages':1},{'customAggregates':False}]:
            self.write('pos-inventory-guards.json',{**guards,**change})
            with self.assertRaises(ValueError):m.inventory_guards('pos',self.area)

    def test_acl_quoted_delimiters_and_grant_options_remain_distinct(self):
        self.assertEqual(m.acl_rows(['"group/a"=r*w/"owner=one"']),
                         [('group/a','r',True,'owner=one'),('group/a','w',False,'owner=one')])
        source={'kind':'schema','meta':{'owner':'postgres','acl':['authenticated=U/postgres']}}
        changed=copy.deepcopy(source);changed['meta']['acl']=['authenticated=UC/postgres']
        self.assertNotEqual(fixture.semantic(source),fixture.semantic(changed))

    def test_default_literal_alias_normalization_does_not_hide_changed_data_or_columns(self):
        definition=" SELECT id,\n 'contract'::text,\n name FROM example;"
        source={'kind':'relation','meta':{'kind':'v','definition':definition,
          'columns':[{'name':'event_type','position':1,'acl':None}]}}
        equivalent=copy.deepcopy(source)
        equivalent['meta']['definition']=definition.replace("'contract'::text,","'contract'::text AS text,")
        self.assertEqual(fixture.semantic(source),fixture.semantic(equivalent))
        different=copy.deepcopy(equivalent);different['meta']['definition']=definition.replace('contract','another')
        self.assertNotEqual(fixture.semantic(source),fixture.semantic(different))
        different=copy.deepcopy(equivalent);different['meta']['columns'][0]['name']='different'
        self.assertNotEqual(fixture.semantic(source),fixture.semantic(different))

    def test_column_grants_are_not_discarded_as_table_privileges(self):
        source={'kind':'relation','meta':{'kind':'r','columns':[
            {'name':'read_at','position':1,'acl':['authenticated=w/postgres']} ]}}
        different=copy.deepcopy(source);different['meta']['columns'][0]['acl']=None
        self.assertNotEqual(fixture.semantic(source),fixture.semantic(different))

    def test_bucket_reference_configuration_rejects_files_and_invalid_privacy(self):
        config={'kind':'storage-bucket-reference-config','businessFilesCollected':False,
                'buckets':[{'id':'evidence','name':'evidence','public':False,
                            'file_size_limit':10485760,'allowed_mime_types':['application/pdf']}]}
        self.write('pos-storage-reference-config.json',config)
        self.assertIsNotNone(m.reference_sql('pos',self.area))
        for change in [{'businessFilesCollected':True},
                       {'buckets':[{**config['buckets'][0],'public':'false'}]},
                       {'buckets':[config['buckets'][0],config['buckets'][0]]},
                       {'buckets':[{**config['buckets'][0],'objects':['private-file']}]}]:
            self.write('pos-storage-reference-config.json',{**config,**change})
            with self.assertRaises(ValueError):m.reference_sql('pos',self.area)


if __name__=='__main__':unittest.main()
