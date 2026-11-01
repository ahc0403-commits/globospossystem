#!/usr/bin/env python3
"""Two separate local DB/Auth fixtures; NOT a full production-schema restore.

The inspected Office baseline and candidate Office migration must be supplied
explicitly. This runner never connects to production or loads its business rows.
"""
import argparse
import hashlib
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import subprocess
import time
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[2]
POS_ACTOR = '10000000-0000-4000-8000-000000000001'
OFFICE_ACTOR = '20000000-0000-4000-8000-000000000001'
TAX = '30000000-0000-4000-8000-000000000001'
OP = '40000000-0000-4000-8000-000000000001'
PROOF = 'synthetic-local-fixture-proof-' + 'x' * 32


def literal(value):
    return "'" + str(value).replace("'", "''") + "'"


class LegalConnectionTests(unittest.TestCase):
    office_root = None
    baseline = None

    @classmethod
    def setUpClass(cls):
        manifest = json.loads((cls.baseline.parent/'manifest.json').read_text())
        for row in manifest['files']:
            candidate = cls.baseline.parent/row['path']
            if hashlib.sha256(candidate.read_bytes()).hexdigest() != row['sha256']:
                raise RuntimeError('Office inspected baseline checksum mismatch')
        cls.container = 'pos-legal-connection-' + uuid.uuid4().hex[:12]
        cls.call(['docker','run','-d','--rm','--network','none','--memory','512m','--cpus','1',
            '--name',cls.container,'-e','POSTGRES_HOST_AUTH_METHOD=trust','postgres:17.6'])
        cls.addClassCleanup(lambda: cls.call(['docker','rm','-f',cls.container],check=False))
        for _ in range(60):
            if subprocess.run(['docker','exec',cls.container,'pg_isready','-U','postgres'],
                    stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode == 0:
                break
            time.sleep(.5)
        else:
            cls.call(['docker','rm','-f',cls.container])
            raise RuntimeError('Local fixture did not start')
        cls.sql('postgres', "CREATE ROLE anon;CREATE ROLE authenticated;CREATE ROLE service_role;"
                "CREATE DATABASE pos_fixture;CREATE DATABASE office_fixture;")
        cls.sql('pos_fixture',(ROOT/'test/fixtures/pos_office_legal_connection_pos.sql').read_text())
        cls.sql('office_fixture',(ROOT/'test/fixtures/pos_office_legal_connection_office.sql').read_text())
        cls.sql('office_fixture',cls.baseline.read_text())
        cls.sql('office_fixture',cls.baseline.with_name('office-procurement-connect-baseline.sql').read_text())
        cls.sql('pos_fixture',(ROOT/'supabase/migrations/20261101023409_pos_office_legal_connection.sql').read_text())
        cls.sql('office_fixture',(cls.office_root/'supabase/migrations/20261101023410_office_first_pos_legal_connection.sql').read_text())

    @staticmethod
    def call(argv, text=None, check=True):
        result=subprocess.run(argv,input=text,text=True,capture_output=True,timeout=45)
        if check and result.returncode:
            raise AssertionError(result.stderr[-3000:])
        return result

    @classmethod
    def sql(cls,db,text,check=True):
        return cls.call(['docker','exec','-i',cls.container,'psql','-X','-U','postgres','-d',db,
            '-v','ON_ERROR_STOP=1','-Atq'],text,check)

    def setUp(self):
        self.sql('pos_fixture',"TRUNCATE public.pos_office_legal_connections;UPDATE public.users SET is_active=true;"
                 "UPDATE public.tax_entity SET name='Fixture legal A' WHERE id="+literal(TAX)+";"
                 "SET request.jwt.claim.role='service_role';SELECT public.office_report_legal_capability_v1(true);")
        self.sql('office_fixture',"TRUNCATE ops.pos_legal_entity_links,ops.stores,ops.legal_entity_brands,ops.brands,"
                 "accounting.legal_entities,system.audit_log CASCADE;"
                 "UPDATE public.office_user_profiles SET is_suspended=false;")

    def pos(self,body,actor=POS_ACTOR,service=False,check=True):
        role='service_role' if service else 'authenticated'
        return self.sql('pos_fixture','SET ROLE '+role+';SET request.jwt.claim.role='+literal(role)+
            ';SET request.jwt.claim.sub='+literal(actor)+';'+body,check)

    def office(self,body,actor=OFFICE_ACTOR,check=True):
        return self.sql('office_fixture',"SET ROLE service_role;SET request.jwt.claim.role='service_role';"+body,check)

    def begin(self):
        return json.loads(self.pos('SELECT public.begin_office_legal_connection_v1('+','.join(map(literal,[OP,TAX,PROOF]))+');').stdout)

    def commit(self,request,actor=OFFICE_ACTOR,existing=None):
        body='SELECT ops.commit_verified_pos_legal_connection_v1('+literal(json.dumps(request))+'::jsonb,'+literal(actor)+','
        body+=(literal(existing)+'::uuid,NULL' if existing else "NULL,'{\"code\":\"NEW\",\"display_name\":\"Fixture new entity\"}'::jsonb")+');'
        return self.office(body,actor)

    def confirm_pos(self,row):
        args=[row['operation_id'],row['payload_sha256'],row['legal_entity_id'],row['office_actor_id'],row['office_confirmed_at']]
        return json.loads(self.pos('SELECT public.office_confirm_pos_legal_connection_v1('+','.join(map(literal,args))+');',service=True).stdout)

    def test_zero_store_new_legal_entity_uses_explicit_independent_auth(self):
        request=self.begin()
        self.assertEqual(self.sql('pos_fixture','SELECT count(*) FROM restaurants').stdout.strip(),'0')
        row=json.loads(self.commit(request).stdout)
        self.assertNotEqual(row['legal_entity_id'],TAX)
        self.assertNotEqual(row['office_actor_id'],request['requested_by'])
        confirmed=self.confirm_pos(row)
        consumed=self.pos('SELECT public.office_resolve_pos_legal_connection_v1('+literal(OP)+','+literal(PROOF)+');',service=True,check=False)
        self.assertIn('POS_OFFICE_LEGAL_CONNECTION_CONSUMED',consumed.stderr)
        ack=self.office('SELECT ops.acknowledge_verified_pos_legal_connection_v1('+literal(OP)+','+literal(OFFICE_ACTOR)+','+literal(json.dumps(confirmed))+'::jsonb);')
        self.assertEqual(json.loads(ack.stdout)['state'],'confirmed')

    def test_twenty_repeated_confirmations_create_once(self):
        request=self.begin()
        results=[json.loads(self.commit(request).stdout) for _ in range(20)]
        self.assertEqual(len({r['legal_entity_id'] for r in results}),1)
        self.assertEqual(self.sql('office_fixture','SELECT count(*) FROM accounting.legal_entities').stdout.strip(),'1')

    def test_concurrent_office_confirmations_create_once(self):
        request=self.begin()
        with ThreadPoolExecutor(max_workers=4) as pool:
            results=list(pool.map(lambda _:json.loads(self.commit(request).stdout),range(20)))
        self.assertEqual(len({r['legal_entity_id'] for r in results}),1)
        self.assertEqual(self.sql('office_fixture','SELECT count(*) FROM accounting.legal_entities').stdout.strip(),'1')

    def test_existing_office_entity_is_selected_instead_of_inferred_from_uuid(self):
        chosen='70000000-0000-4000-8000-000000000001'
        self.sql('office_fixture','INSERT INTO accounting.legal_entities(id,code,display_name) VALUES('
          +literal(TAX)+",'COINCIDENTAL','Not the chosen owner'),("+literal(chosen)+",'CHOSEN','Explicitly chosen owner');")
        row=json.loads(self.commit(self.begin(),existing=chosen).stdout)
        self.assertEqual(row['legal_entity_id'],chosen)
        self.assertEqual(self.sql('office_fixture','SELECT count(*) FROM accounting.legal_entities').stdout.strip(),'2')

    def test_office_commit_can_be_acknowledged_after_network_delay_past_expiry(self):
        row=json.loads(self.commit(self.begin()).stdout)
        # Explicit fixture clock data: the Office commit predates expiry while
        # the acknowledgement occurs later. This is not elapsed soak evidence.
        self.sql('pos_fixture',"UPDATE pos_office_legal_connections SET created_at=now()-interval '1 hour',expires_at=now()-interval '1 minute';")
        self.sql('office_fixture',"UPDATE ops.pos_legal_entity_links SET office_confirmed_at=now()-interval '10 minutes';")
        row=json.loads(self.office('SELECT ops.get_verified_pos_legal_connection_v1('+literal(OP)+','+literal(OFFICE_ACTOR)+');').stdout)
        self.assertEqual(self.confirm_pos(row)['state'],'confirmed')

    def test_source_change_before_preview_and_revoked_pos_actor_are_rejected(self):
        self.begin()
        self.sql('pos_fixture',"UPDATE tax_entity SET name='Changed before preview' WHERE id="+literal(TAX))
        denied=self.pos('SELECT public.office_resolve_pos_legal_connection_v1('+literal(OP)+','+literal(PROOF)+');',service=True,check=False)
        self.assertIn('POS_OFFICE_LEGAL_ENTITY_CHANGED',denied.stderr)
        self.sql('pos_fixture',"UPDATE users SET is_active=false WHERE auth_id="+literal(POS_ACTOR))
        denied=self.pos('SELECT public.office_resolve_pos_legal_connection_v1('+literal(OP)+','+literal(PROOF)+');',service=True,check=False)
        self.assertIn('POS_OFFICE_LEGAL_CONNECTION_ACTOR_REVOKED',denied.stderr)

    def test_concurrent_same_operation_has_one_request(self):
        with ThreadPoolExecutor(max_workers=4) as pool:
            rows=list(pool.map(lambda _:self.begin(),range(20)))
        self.assertEqual({r['operation_id'] for r in rows},{OP})
        self.assertEqual(self.sql('pos_fixture','SELECT count(*) FROM pos_office_legal_connections').stdout.strip(),'1')

    def test_wrong_pos_actor_or_proof_is_denied(self):
        self.begin()
        bad=self.pos('SELECT public.get_office_legal_connection_v1('+literal(OP)+');',actor=POS_ACTOR[:-1]+'3',check=False)
        self.assertNotEqual(bad.returncode,0)
        bad=self.pos('SELECT public.office_resolve_pos_legal_connection_v1('+literal(OP)+",'incorrect-proof');",service=True,check=False)
        self.assertNotEqual(bad.returncode,0)

    def test_restricted_office_actor_cannot_create_a_legal_entity(self):
        request=self.begin()
        with self.assertRaises(AssertionError):self.commit(request,actor=OFFICE_ACTOR[:-1]+'2')
        self.assertEqual(self.sql('office_fixture','SELECT count(*) FROM accounting.legal_entities').stdout.strip(),'0')

    def test_external_legal_entity_does_not_inherit_internal_policy(self):
        bad=self.pos('SELECT public.begin_office_legal_connection_v1('+literal(OP)+','+literal(TAX[:-1]+'3')+','+literal(PROOF)+');',check=False)
        self.assertNotEqual(bad.returncode,0)
        self.assertIn('POS_OFFICE_EXTERNAL_LEGAL_ENTITY_UNSUPPORTED',bad.stderr)

    def test_expired_or_changed_source_is_rejected_before_office_creation(self):
        self.begin()
        self.sql('pos_fixture',"UPDATE pos_office_legal_connections SET created_at=now()-interval '1 hour',expires_at=now()-interval '1 minute';")
        bad=self.pos('SELECT public.office_resolve_pos_legal_connection_v1('+literal(OP)+','+literal(PROOF)+');',service=True,check=False)
        self.assertIn('POS_OFFICE_LEGAL_CONNECTION_EXPIRED',bad.stderr)

    def test_source_change_after_office_commit_requires_review(self):
        row=json.loads(self.commit(self.begin()).stdout)
        self.sql('pos_fixture',"UPDATE tax_entity SET name='Changed after confirmation' WHERE id="+literal(TAX))
        result=self.confirm_pos(row)
        self.assertEqual(result['state'],'requires_review')

    def test_first_store_uses_acknowledged_legal_mapping_without_seed_anchor(self):
        row=json.loads(self.commit(self.begin()).stdout);confirmed=self.confirm_pos(row)
        self.office('SELECT ops.acknowledge_verified_pos_legal_connection_v1('+literal(OP)+','+literal(OFFICE_ACTOR)+','+literal(json.dumps(confirmed))+'::jsonb);')
        manifest=[{'store_id':'50000000-0000-4000-8000-000000000001','store_name':'First store','brand_id':'60000000-0000-4000-8000-000000000001','brand_name':'Fixture brand','tax_entity_id':TAX,'is_active':True}]
        result=self.office('SELECT ops.connect_verified_pos_stores('+literal(json.dumps(manifest))+'::jsonb,'+literal(OFFICE_ACTOR)+');')
        self.assertEqual(json.loads(result.stdout)['created_store_count'],1)
        self.assertEqual(self.sql('office_fixture','SELECT legal_entity_id FROM ops.stores').stdout.strip(),row['legal_entity_id'])

    def test_authenticated_roles_cannot_call_service_confirmation(self):
        self.begin()
        result=self.pos('SELECT public.office_resolve_pos_legal_connection_v1('+literal(OP)+','+literal(PROOF)+');',check=False)
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(self.sql('office_fixture',"SELECT has_table_privilege('authenticated','ops.pos_legal_entity_links','SELECT')").stdout.strip(),'f')

    def test_new_connection_waits_for_office_capability_but_existing_operation_can_resume(self):
        first=self.begin()
        self.sql('pos_fixture','TRUNCATE public.pos_office_legal_capability;')
        self.assertEqual(self.begin()['operation_id'],first['operation_id'])
        self.sql('pos_fixture','TRUNCATE public.pos_office_legal_connections;')
        with self.assertRaisesRegex(AssertionError,'POS_OFFICE_LEGAL_CAPABILITY_NOT_READY'):
            self.begin()

    def test_expired_office_capability_is_not_ready(self):
        self.sql('pos_fixture',"UPDATE public.pos_office_legal_capability SET reported_at=now()-interval '16 minutes';")
        state=json.loads(self.pos('SELECT public.get_office_legal_capability_v1();').stdout)
        self.assertFalse(state['ready'])
        denied=self.pos('SELECT public.office_report_legal_capability_v1(true);',check=False)
        self.assertNotEqual(denied.returncode,0)

    def test_actor_revoked_after_office_commit_requires_review(self):
        row=json.loads(self.commit(self.begin()).stdout)
        self.sql('pos_fixture',"UPDATE users SET is_active=false WHERE auth_id="+literal(POS_ACTOR))
        self.assertEqual(self.confirm_pos(row)['state'],'requires_review')

    def connected_store(self):
        row=json.loads(self.commit(self.begin()).stdout);confirmed=self.confirm_pos(row)
        self.office('SELECT ops.acknowledge_verified_pos_legal_connection_v1('+literal(OP)+','+literal(OFFICE_ACTOR)+','+literal(json.dumps(confirmed))+'::jsonb);')
        manifest=[{'store_id':'50000000-0000-4000-8000-000000000001','store_name':'First store','brand_id':'60000000-0000-4000-8000-000000000001','brand_name':'Fixture brand','tax_entity_id':TAX,'is_active':True}]
        self.office('SELECT ops.connect_verified_pos_stores('+literal(json.dumps(manifest))+'::jsonb,'+literal(OFFICE_ACTOR)+');')
        return [{'id':r['store_id'],'name':r['store_name'],'brand_id':r['brand_id'],'tax_entity_id':r['tax_entity_id']} for r in manifest]

    def test_procurement_uses_explicit_office_brand_and_preserves_pos_business_ids(self):
        incoming=self.connected_store()
        result=json.loads(self.office('SELECT public.connect_procurement_pos_stores('+literal(json.dumps(incoming))+'::jsonb);').stdout)
        self.assertEqual(result['blocked'],[])
        self.assertEqual(len(result['connected']),1)
        row=result['connected'][0]
        self.assertEqual(row['brand_id'],incoming[0]['brand_id'])
        self.assertNotEqual(row['office_brand_id'],incoming[0]['brand_id'])
        self.assertEqual(row['principals'][0]['subject_id'],OFFICE_ACTOR)
        self.assertNotEqual(row['principals'][0]['subject_id'],POS_ACTOR)

    def test_suspended_office_principal_is_not_synced_to_pos_readiness(self):
        incoming=self.connected_store()
        self.sql('office_fixture',"UPDATE office_user_profiles SET is_suspended=true WHERE auth_id="+literal(OFFICE_ACTOR))
        result=json.loads(self.office('SELECT public.connect_procurement_pos_stores('+literal(json.dumps(incoming))+'::jsonb);').stdout)
        self.assertEqual(result['connected'][0]['principals'],[])

    def test_legacy_equal_brand_mapping_remains_batched_without_join_duplication(self):
        legal='70000000-0000-4000-8000-000000000001';brand='60000000-0000-4000-8000-000000000001'
        first='50000000-0000-4000-8000-000000000001';second='50000000-0000-4000-8000-000000000002'
        self.sql('office_fixture','INSERT INTO accounting.legal_entities(id,code,display_name) VALUES('+literal(legal)+",'OLD','Legacy');"
            'INSERT INTO ops.brands(id,name,status) VALUES('+literal(brand)+",'Legacy brand','active');"
            'INSERT INTO ops.stores(name,status,brand_id,legal_entity_id,pos_store_id,pos_tax_entity_id) VALUES '
            "('Legacy A','active',"+literal(brand)+','+literal(legal)+','+literal(first)+',NULL),'
            "('Legacy B','active',"+literal(brand)+','+literal(legal)+','+literal(second)+','+literal(TAX)+');')
        incoming=[{'id':first,'name':'Legacy A','brand_id':brand,'tax_entity_id':TAX}]
        result=json.loads(self.office('SELECT public.connect_procurement_pos_stores('+literal(json.dumps(incoming))+'::jsonb);').stdout)
        self.assertEqual(len(result['connected']),1)
        self.assertEqual(result['blocked'],[])
        self.assertEqual(result['connected'][0]['office_brand_id'],brand)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--office-root',type=Path,required=True)
    parser.add_argument('--office-baseline',type=Path,default=ROOT/'test/fixtures/office_legal_connection_baselines/office-store-mapping-baseline.sql')
    args,unknown=parser.parse_known_args()
    LegalConnectionTests.office_root=args.office_root.resolve()
    LegalConnectionTests.baseline=args.office_baseline.resolve()
    unittest.main(argv=[__file__,*unknown])
