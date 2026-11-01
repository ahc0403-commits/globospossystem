import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest

import test_schema_snapshot as schema_test

spec=importlib.util.spec_from_file_location('storage_runtime',Path(__file__).parents[1]/'storage_runtime.py')
storage=importlib.util.module_from_spec(spec);spec.loader.exec_module(storage)


class StorageRuntimeGuards(unittest.TestCase):
    def setUp(self):
        self.area=Path(tempfile.mkdtemp(prefix='owned-storage-reference-'))
        self.addCleanup(lambda:__import__('shutil').rmtree(self.area))
        self.path=self.area/'reference.json'
        source=schema_test.m
        objects=[{'kind':'schema','ident':'storage','sha256':'a'*64}]
        fingerprint=hashlib.sha256(source.runtime.pg_jsonb([['schema','storage','a'*64]]).encode()).hexdigest()
        self.schema=SimpleNamespace(private=source.private,require=source.require,runtime=source.runtime,PROJECTS=source.PROJECTS,
          load=lambda *_:({},objects))
        self.platform=SimpleNamespace(schema=self.schema,snapshot=self.area)
        self.history=[{'id':n,'name':'migration-'+str(n),'hash':'a'*40} for n in range(74)]
        self.history[-1]['name']='revoke-grants-to-unused-operations'
        self.value={'kind':'source-storage-migration-reference-only','projectRef':source.PROJECTS['pos'],
          'productionModified':False,'businessDataCollected':False,
          'sourceFingerprint':{'storage_schema_sha256':fingerprint,'object_count':1},'migrations':self.history}
        self.write()

    def write(self):
        self.path.write_text(json.dumps(self.value));self.path.chmod(0o600)

    def test_exact_reference_is_loaded_with_its_original_hash(self):
        value,digest=storage.load_reference(self.platform,'pos',self.path)
        self.assertEqual(value,self.value);self.assertEqual(digest,hashlib.sha256(self.path.read_bytes()).hexdigest())

    def test_wrong_project_or_schema_fingerprint_cannot_seed_migration_history(self):
        self.value['projectRef']=self.schema.PROJECTS['office'];self.write()
        with self.assertRaisesRegex(ValueError,'project/source'):storage.load_reference(self.platform,'pos',self.path)
        self.value['projectRef']=self.schema.PROJECTS['pos'];self.value['sourceFingerprint']['storage_schema_sha256']='0'*64;self.write()
        with self.assertRaisesRegex(ValueError,'captured native schema'):storage.load_reference(self.platform,'pos',self.path)

    def test_partial_or_duplicate_history_cannot_be_reported_as_restored(self):
        for rows in [self.history[-1:],self.history[:-1],self.history+[self.history[0]]]:
            self.value['migrations']=rows;self.write()
            with self.assertRaises(ValueError):storage.load_reference(self.platform,'pos',self.path)

    def test_world_readable_or_symlink_reference_is_rejected(self):
        self.path.chmod(0o644)
        with self.assertRaises(ValueError):storage.load_reference(self.platform,'pos',self.path)
        self.path.chmod(0o600);link=self.area/'linked.json';link.symlink_to(self.path)
        with self.assertRaises(ValueError):storage.load_reference(self.platform,'pos',link)

    def test_only_reviewed_hash_refresh_preserves_all_ids_and_names(self):
        after=json.loads(json.dumps(self.history));after[2]['hash']='b'*40;after[62]['hash']='c'*40
        self.assertEqual(storage.validate_history_refresh(self.history,after),[2,62])
        for changed in [after+[{'id':74,'name':'new-migration','hash':'d'*40}],
                        [{**r,'name':'renamed'} if r['id']==2 else r for r in after],
                        [{**r,'hash':'d'*40} if r['id']==3 else r for r in after]]:
            with self.assertRaises(ValueError):storage.validate_history_refresh(self.history,changed)


if __name__=='__main__':unittest.main()
