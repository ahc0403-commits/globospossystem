import copy
import hashlib
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))
import fixture_image as image

loader = importlib.machinery.SourceFileLoader('projection_fixture_docker', str(HERE/'docker'))
spec = importlib.util.spec_from_loader(loader.name, loader)
wrapper = importlib.util.module_from_spec(spec)
loader.exec_module(wrapper)


class FixtureImageTests(unittest.TestCase):
    def setUp(self):
        environment = patch.dict(os.environ, {'POS_FIXTURE_IMAGE_MAP':'{}', 'POS_POSTGRES_FIXTURE_IMAGE':''})
        environment.start()
        self.addCleanup(environment.stop)
        self.fixed = image.policy()
        self.config = {'Env':['PATH=/bin'], 'Entrypoint':['entry'], 'Cmd':['postgres'],
            'User':'fixture', 'WorkingDir':'/', 'ArgsEscaped':True,
            'Healthcheck':{'Test':['CMD-SHELL','pg_isready'],'Interval':2000000000}}
        self.fixed['runtimeConfigKeys'] = list(self.config)
        self.fixed['runtimeConfigSha256'] = image.digest(image.canonical(self.config))
        self.value = {'Id':self.fixed['derivedImageId'],'Os':'linux','Architecture':'amd64',
            'Config':self.config,'RootFS':{'Layers':['sha256:'+self.fixed['rootfsArchiveSha256']]}}

    def test_immutable_rootfs_and_full_runtime_metadata_are_required(self):
        self.assertEqual(image.validate_image(self.value,self.fixed),self.fixed['derivedImageId'])
        for field,value in [('Env',['PATH=/other']),('Entrypoint',['other']),('Cmd',['other']),
                            ('User','root'),('WorkingDir','/other'),('ArgsEscaped',False),('Healthcheck',None)]:
            changed=copy.deepcopy(self.value);changed['Config'][field]=value
            with self.subTest(field=field),self.assertRaises(ValueError):image.validate_image(changed,self.fixed)

    def test_system_docker_fallback_never_resolves_the_path_wrapper(self):
        with patch.object(wrapper.os.path,'isfile',side_effect=lambda p:p=='/usr/local/bin/docker'), \
             patch.object(wrapper.os,'access',return_value=True):
            self.assertEqual(wrapper.real_docker(),'/usr/local/bin/docker')
        with patch.object(wrapper.os.path,'isfile',return_value=False):
            with self.assertRaises(ValueError):wrapper.real_docker()

    def test_wrong_image_architecture_or_layer_cannot_be_relabelled_as_valid(self):
        for mutation in ['id','arch','layer','extra-layer']:
            changed=copy.deepcopy(self.value)
            if mutation=='id':changed['Id']='sha256:'+'0'*64
            if mutation=='arch':changed['Architecture']='arm64'
            if mutation=='layer':changed['RootFS']['Layers']=['sha256:'+'0'*64]
            if mutation=='extra-layer':changed['RootFS']['Layers'].append('sha256:'+'0'*64)
            with self.subTest(mutation=mutation),self.assertRaises(ValueError):image.validate_image(changed,self.fixed)

    def test_stale_foreign_or_substituted_provenance_is_rejected(self):
        keys=('representation','requestedRef','sourceRef','sourceManifestDigest','sourceConfigDigest',
              'sourceRootfsInventorySha256','rootfsArchiveSha256','runtimeConfigSha256','derivedImageId','os','architecture')
        proof={k:self.fixed[k] for k in keys}
        proof.update(schemaVersion=1,runId='a'*32,sourceSha='b'*40,rootfsLayers=self.value['RootFS']['Layers'])
        image.verify_proof(proof,'a'*32,'b'*40,self.fixed)
        for field in ['runId','sourceSha','sourceManifestDigest','sourceConfigDigest','rootfsArchiveSha256','derivedImageId']:
            changed=copy.deepcopy(proof);changed[field]='forged'
            with self.subTest(field=field),self.assertRaises(ValueError):image.verify_proof(changed,'a'*32,'b'*40,self.fixed)

    def test_projection_preserves_config_and_rejects_changed_source_bytes(self):
        source={'os':'linux','architecture':'amd64','created':'2026-01-01T00:00:00Z',
                'config':self.config,'rootfs':{'type':'layers','diff_ids':['sha256:source']},'history':[]}
        raw=image.canonical(source);self.fixed['sourceConfigDigest']='sha256:'+image.digest(raw)
        expected=copy.deepcopy(source)
        expected['rootfs']={'type':'layers','diff_ids':self.value['RootFS']['Layers']}
        expected['history']=[{'created':source['created'],'created_by':'POS verified rootfs projection v1',
                             'comment':self.fixed['sourceManifestDigest']}]
        self.fixed['derivedImageId']='sha256:'+image.digest(image.canonical(expected))
        result=json.loads(image.projected_config(raw,self.fixed))
        self.assertEqual(result['config'],source['config'])
        self.assertEqual(source['rootfs']['diff_ids'],['sha256:source'])
        with self.assertRaises(ValueError):image.projected_config(raw+b' ',self.fixed)

    def test_wrapper_changes_only_the_explicit_pinned_source(self):
        projected=self.fixed['derivedImageId'];requested=self.fixed['requestedRef']
        with patch.dict(os.environ,{'POS_POSTGRES_FIXTURE_IMAGE':projected}), \
             patch.object(wrapper.subprocess,'run') as execute, \
             patch.object(wrapper,'verified_fixture_id',return_value=projected) as validate:
            execute.return_value.returncode=1
            args=wrapper.prepare(['run','--name','owned',requested], 'f'*32)
            self.assertIn(projected,args);self.assertNotIn(requested,args)
            self.assertIn('pos.local.fixture.source='+requested,args)
            validate.assert_called_once_with(projected,[wrapper.REAL])
            for other in ['postgres:15','postgres:17.6','postgres:17-alpine','public.ecr.aws/supabase/postgrest:v14.5']:
                result=wrapper.prepare(['run','--name','owned',other],'f'*32)
                self.assertIn(other,result);self.assertNotIn(projected,result)

    def test_wrapper_refuses_invalid_override_before_container_creation(self):
        with patch.dict(os.environ,{'POS_POSTGRES_FIXTURE_IMAGE':'sha256:'+'0'*64}), \
             patch.object(wrapper.subprocess,'run') as execute, \
             patch.object(wrapper,'verified_fixture_id',side_effect=ValueError('wrong image')):
            execute.return_value.returncode=1
            with self.assertRaises(ValueError):wrapper.prepare(['run','--name','owned',self.fixed['requestedRef']],'f'*32)

    def test_stock_versions_have_distinct_preserved_identities(self):
        fixed = image.policies()
        self.assertEqual(len(fixed), 5)
        self.assertEqual(len({p['sourceConfigDigest'] for p in fixed}), 5)
        self.assertEqual(len({p['derivedImageId'] for p in fixed}), 5)
        projections = {p['requestedRef']:p['derivedImageId'] for p in fixed}
        with patch.dict(os.environ, {'POS_FIXTURE_IMAGE_MAP':json.dumps(projections),
                                    'POS_POSTGRES_FIXTURE_IMAGE':''}), \
             patch.object(wrapper.subprocess,'run') as execute, \
             patch.object(wrapper,'verified_fixture_id') as validate:
            execute.return_value.returncode = 1
            for policy in fixed:
                result = wrapper.prepare(['run','--name','owned',policy['requestedRef']], 'f'*32)
                self.assertIn(policy['derivedImageId'], result)
                self.assertIn('pos.local.fixture.source='+policy['requestedRef'], result)
                validate.assert_called_with(policy['derivedImageId'], [wrapper.REAL])
            reference = 'public.ecr.aws/supabase/postgrest:v14.5'
            self.assertIn(reference, wrapper.prepare(['run','--name','owned',reference], 'f'*32))

    def test_map_cannot_cross_versions_inject_unknown_or_ambiguous_sources(self):
        policies = image.policies()
        a, b = policies[:2]
        mappings = [{a['requestedRef']:b['derivedImageId']}, {'unreviewed:latest':a['derivedImageId']}, []]
        for mapping in mappings:
            with self.subTest(mapping=mapping), \
                 patch.dict(os.environ, {'POS_FIXTURE_IMAGE_MAP':json.dumps(mapping),
                                         'POS_POSTGRES_FIXTURE_IMAGE':''}), \
                 patch.object(wrapper.subprocess,'run') as execute:
                execute.return_value.returncode = 1
                with self.assertRaises(ValueError):
                    wrapper.prepare(['run','--name','owned',a['requestedRef']], 'f'*32)
        mapping = {p['requestedRef']:p['derivedImageId'] for p in policies}
        with patch.dict(os.environ, {'POS_FIXTURE_IMAGE_MAP':json.dumps(mapping),
                                    'POS_POSTGRES_FIXTURE_IMAGE':''}), \
             patch.object(wrapper.subprocess,'run') as execute:
            execute.return_value.returncode = 1
            with self.assertRaises(ValueError):
                wrapper.prepare(['run','--name','owned',a['requestedRef'],b['requestedRef']], 'f'*32)

    def test_disk_peak_is_observed_and_stop_is_idempotent(self):
        with tempfile.TemporaryDirectory() as directory:
            monitor=image.DiskMonitor(directory)
            with patch.object(image.os,'statvfs',side_effect=[
                SimpleNamespace(f_bavail=100,f_frsize=1,f_blocks=300,f_bfree=100),
                SimpleNamespace(f_bavail=40,f_frsize=1,f_blocks=300,f_bfree=40),
                SimpleNamespace(f_bavail=80,f_frsize=1,f_blocks=300,f_bfree=80)]):
                monitor.sample();monitor.sample();result=monitor.stop()
                self.assertIs(monitor.stop(),result)
            self.assertEqual(result['minimumAvailableBytes'],40)
            self.assertEqual(result['maximumUsedBytes'],260)

    def test_only_new_stock_fixture_data_uses_reviewed_temporary_storage(self):
        for fixed in image.policies():
            options = image.temporary_volume_options(fixed)
            if fixed['requestedRef'].startswith(('postgres:','public.ecr.aws/supabase/postgres:')):
                self.assertEqual(options, {'/var/lib/postgresql/data':'rw,size=1073741824'})
                good = {'HostConfig':{'Tmpfs':options},'Mounts':[]}
                self.assertEqual(image.validate_temporary_storage(good,fixed), options)
                for changed in [{}, {'HostConfig':{'Tmpfs':{'/var/lib/postgresql/data':'rw,size=1'}}},
                                {'HostConfig':{'Tmpfs':options},'Mounts':[{'Destination':'/var/lib/postgresql/data','Type':'volume'}]}]:
                    with self.assertRaises(ValueError):image.validate_temporary_storage(changed,fixed)
            else:
                self.assertEqual(options,{})
        for path,size in [('/',1073741824),('/var/lib/postgresql/data',1)]:
            fixed=copy.deepcopy(self.fixed);fixed['temporaryVolumes']={path:size}
            with self.assertRaises(ValueError):image.temporary_volume_options(fixed)

    def test_temporary_database_mount_is_explicit_and_cannot_cover_a_supplied_mount(self):
        fixed=image.policy_for_ref('postgres:17.6')
        mapping={fixed['requestedRef']:fixed['derivedImageId']}
        with patch.dict(os.environ,{'POS_FIXTURE_IMAGE_MAP':json.dumps(mapping)}), \
             patch.object(wrapper.subprocess,'run') as execute, \
             patch.object(wrapper,'verified_fixture_id'):
            execute.return_value.returncode=1
            result=wrapper.prepare(['run','--name','owned','postgres:17.6'],'f'*32)
            self.assertIn('/var/lib/postgresql/data:rw,size=1073741824',result)
            for flag in ['--mount','--volume','-v','--tmpfs','--mount=existing','--volume=existing','-vexisting','--tmpfs=existing']:
                with self.subTest(flag=flag), self.assertRaises(ValueError):
                    wrapper.prepare(['run','--name','owned',flag,'existing','postgres:17.6'],'f'*32)


if __name__=='__main__':unittest.main()
