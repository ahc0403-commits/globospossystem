import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest

import test_schema_snapshot as schema_test

spec=importlib.util.spec_from_file_location('realtime_runtime',Path(__file__).parents[1]/'realtime_runtime.py')
realtime=importlib.util.module_from_spec(spec);spec.loader.exec_module(realtime)


class RealtimeReferenceGuards(unittest.TestCase):
    def setUp(self):
        self.area=Path(tempfile.mkdtemp(prefix='owned-realtime-reference-'))
        self.addCleanup(lambda:__import__('shutil').rmtree(self.area))
        self.path=self.area/'reference.json'
        self.platform=SimpleNamespace(schema=schema_test.m)
        self.value={'kind':'source-realtime-authorization-reference-only','projectRef':schema_test.m.PROJECTS['pos'],
          'productionModified':False,'businessDataCollected':False,
          'policies':[{'name':'captured_kds_read','command':'r','permissive':True,'roles':['authenticated'],
            'using':"realtime.topic() LIKE 'kds:%'",'check':None}],
          'migrationVersions':['20200101000000'],'routines':[{'signature':'realtime.topic()', 'definitionSha256':'a'*64}]}
        self.write()

    def write(self):self.path.write_text(json.dumps(self.value));self.path.chmod(0o600)

    def test_original_private_project_reference_retains_its_hash(self):
        value,digest=realtime.load_reference(self.platform,'pos',self.path)
        self.assertEqual(value,self.value);self.assertEqual(digest,hashlib.sha256(self.path.read_bytes()).hexdigest())

    def test_other_project_or_data_capture_cannot_supply_authorization(self):
        self.value['projectRef']=schema_test.m.PROJECTS['office'];self.write()
        with self.assertRaisesRegex(ValueError,'scope'):realtime.load_reference(self.platform,'pos',self.path)
        self.value['projectRef']=schema_test.m.PROJECTS['pos'];self.value['businessDataCollected']=True;self.write()
        with self.assertRaisesRegex(ValueError,'scope'):realtime.load_reference(self.platform,'pos',self.path)

    def test_reference_cannot_change_into_an_arbitrary_sql_script_or_role(self):
        for field,value in [('command','DROP'),('roles',['supabase_admin']),('using','true; SELECT 1')]:
            previous=self.value['policies'][0][field];self.value['policies'][0][field]=value;self.write()
            with self.subTest(field=field),self.assertRaises(ValueError):realtime.load_reference(self.platform,'pos',self.path)
            self.value['policies'][0][field]=previous

    def test_duplicate_policy_or_missing_runtime_provenance_is_rejected(self):
        self.value['policies']*=2;self.write()
        with self.assertRaisesRegex(ValueError,'Duplicate'):realtime.load_reference(self.platform,'pos',self.path)
        self.value['policies']=[];self.value['migrationVersions']=[];self.write()
        with self.assertRaises(ValueError):realtime.load_reference(self.platform,'pos',self.path)

    def test_world_readable_and_symlink_sources_are_rejected(self):
        self.path.chmod(0o644)
        with self.assertRaises(ValueError):realtime.load_reference(self.platform,'pos',self.path)
        self.path.chmod(0o600);link=self.area/'linked.json';link.symlink_to(self.path)
        with self.assertRaises(ValueError):realtime.load_reference(self.platform,'pos',link)

    def test_actual_release_config_never_installs_control_tables_in_public(self):
        values=realtime.environment({'db':'fixture-db','password':'fixture-only','secret':'x'*64},
          'realtime-pos','e'*16,'s'*128)
        self.assertEqual(values['APP_NAME'],'realtime')
        self.assertEqual(values['DB_AFTER_CONNECT_QUERY'],'SET search_path TO _realtime')
        self.assertEqual(values['SEED_SELF_HOST'],'true')
        self.assertEqual(values['DB_POOL_SIZE'],'2')


if __name__=='__main__':unittest.main()
