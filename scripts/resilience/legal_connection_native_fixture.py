"""Reuse connection business cases against two native, independent owned DBs.

Auth table/ACL/RLS contracts are native; this is not a GoTrue/browser/device E2E.
Only synthetic principals and the two required permission catalog entries exist.
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import time
import unittest
import uuid

ROOT=Path(__file__).resolve().parents[2]
SOURCE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('legal_business_cases',SOURCE/'integration_legal_connection.py')
cases=importlib.util.module_from_spec(spec);spec.loader.exec_module(cases)


def run(pos_container,cmd,schema,semantic,area,office_root):
    """POS has already passed native restoration and candidate migration checks."""
    office_container='pos-native-office-legal-'+uuid.uuid4().hex[:12]
    detail={'fixtureSha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            'casesSha256':hashlib.sha256((SOURCE/'integration_legal_connection.py').read_bytes()).hexdigest(),
            'twoIndependentPostgresInstances':True,'nativeFunctionsStubbed':False,
            'realAuthServiceExercised':False,'browserFlowExercised':False,
            'productionModified':False}
    detail['runId']=os.environ['POS_LOCAL_RUN_ID']
    detail['officeSourceSha']=subprocess.check_output(['git','rev-parse','HEAD'],cwd=office_root,text=True).strip()
    detail['officeWorkingTreeChangesPresent']=bool(subprocess.check_output(['git','status','--porcelain'],cwd=office_root,text=True))
    def sql(project,body,check=True):
        return cmd(['docker','exec','-i','--env','PGPASSWORD=fixture-only',
          '--env','PGOPTIONS=-c supautils.hint_roles=',
          pos_container if project=='pos' else office_container,
          'psql','-X','-qAt','-U','supabase_admin','-d','postgres','-v','ON_ERROR_STOP=1'],
          body,check)
    def seed_office():
        sql('office',"""
SET request.jwt.claim.role='service_role';
INSERT INTO auth.users(id,email,instance_id,aud,role,email_confirmed_at)
SELECT ('20000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,
 'native-office-'||n||'@fixture.invalid','00000000-0000-0000-0000-000000000000',
 'authenticated','authenticated',now() FROM generate_series(1,2)n ON CONFLICT(id) DO NOTHING;
INSERT INTO public.office_user_profiles(id,auth_id,account_level,display_name,email,
 domain_authorities,permission_model_version,is_active,is_suspended,credential_state)
SELECT ('21000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,
 ('20000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,
 CASE WHEN n=1 THEN 'super_admin' ELSE 'staff' END,'Native fixture '||n,
 'native-office-'||n||'@fixture.invalid','[{"domain":"purchase"},{"domain":"finance"}]'::jsonb,
 'v2',true,false,'active' FROM generate_series(1,2)n
ON CONFLICT(auth_id) DO UPDATE SET account_level=excluded.account_level,
 domain_authorities=excluded.domain_authorities,permission_model_version='v2',
 is_active=true,is_suspended=false,credential_state='active';
INSERT INTO core.office_permission_catalog(domain,action,display_name)
VALUES('system','admin','Synthetic system admin'),('purchase','approve','Synthetic purchase approval')
ON CONFLICT(domain,action) DO NOTHING;
INSERT INTO core.office_access_grants(user_profile_id,domain,action,scope_level,is_active,valid_from,granted_by,reason)
SELECT p.id,x.domain,x.action,'group',true,now()-interval '1 hour',
 '20000000-0000-4000-8000-000000000001','Synthetic native connection fixture'
FROM public.office_user_profiles p CROSS JOIN(VALUES('system','admin'),('purchase','approve'))x(domain,action)
WHERE p.auth_id='20000000-0000-4000-8000-000000000001'
 AND NOT EXISTS(SELECT 1 FROM core.office_access_grants g
   WHERE g.user_profile_id=p.id AND g.domain=x.domain AND g.action=x.action AND g.scope_level='group');
""")

    class NativeCases(cases.LegalConnectionTests):
        @classmethod
        def setUpClass(cls):
            cls.office_root=office_root
            sql('pos',"""
-- Native POS profiles require an existing restaurant. Model the pre-existing
-- platform operator in an unrelated legal entity, never a store/mapping anchor
-- for the NEW entity under test. Empty-law is distinct from empty deployment.
INSERT INTO public.companies(id,name) VALUES('62000000-0000-4000-8000-000000000099','Synthetic platform context');
INSERT INTO public.brand_master(id,company_id,name,type)
VALUES('61000000-0000-4000-8000-000000000099','62000000-0000-4000-8000-000000000099','Synthetic platform','internal');
INSERT INTO public.brands(id,brand_master_id,code,name)
VALUES('60000000-0000-4000-8000-000000000099','61000000-0000-4000-8000-000000000099','native_platform','Synthetic platform');
INSERT INTO public.tax_entity(id,name,tax_code,owner_type)
VALUES('30000000-0000-4000-8000-000000000099','Pre-existing unrelated operator context','9100000099','internal');
INSERT INTO public.tax_entity_brands(tax_entity_id,brand_id)
VALUES('30000000-0000-4000-8000-000000000099','60000000-0000-4000-8000-000000000099');
INSERT INTO public.restaurants(id,name,brand_id,tax_entity_id)
VALUES('50000000-0000-4000-8000-000000000099','Pre-existing operator context',
 '60000000-0000-4000-8000-000000000099','30000000-0000-4000-8000-000000000099');
INSERT INTO auth.users(id,email,instance_id,aud,role,email_confirmed_at)
SELECT ('10000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,
 'native-pos-'||n||'@fixture.invalid','00000000-0000-0000-0000-000000000000',
 'authenticated','authenticated',now() FROM generate_series(1,3)n;
INSERT INTO public.users(auth_id,restaurant_id,role,full_name,is_active)
SELECT ('10000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,
 '50000000-0000-4000-8000-000000000099',
 CASE WHEN n=2 THEN 'cashier' ELSE 'super_admin' END,'Native POS fixture '||n,true
 FROM generate_series(1,3)n;
INSERT INTO public.tax_entity(id,name,tax_code,owner_type)
SELECT ('30000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,
 'Native legal '||n,'910000000'||n,CASE WHEN n=3 THEN 'external' ELSE 'internal' END
 FROM generate_series(1,3)n;
""")
            seed_office()
            detail['posAdminHasExistingUnrelatedStoreContext']=True

        @classmethod
        def sql(cls,db,text,check=True):
            result=sql('pos' if db=='pos_fixture' else 'office',text,False)
            if check and result.returncode:
                raise AssertionError(result.stderr[-3000:])
            return result

        def setUp(self):
            super().setUp()
            # Native CASCADE relationships may remove scoped synthetic grants.
            # Re-establish only the fixture's independent global principals.
            seed_office()

    started=time.monotonic()
    try:
        cmd(['docker','run','--detach','--rm','--network','none','--memory','2g','--cpus','2',
             '--name',office_container,'--env','POSTGRES_PASSWORD=fixture-only',
             'public.ecr.aws/supabase/postgres:17.6.1.104'])
        for _ in range(60):
            if cmd(['docker','exec',office_container,'pg_isready','-h','127.0.0.1','-U','postgres'],check=False).returncode==0:break
            time.sleep(.5)
        else:raise RuntimeError('Owned native Office fixture was not ready')
        manifest,objects=schema.load('office',area)
        sql('office',schema.native_restore_sql('office',area))
        references=schema.reference_sql('office',area)
        if references:sql('office',references)
        query=(SOURCE/'schema_export.sql').read_text().replace('/*SCOPE*/',','.join(map(schema.lit,manifest['scope']))).replace('/*PAGE*/','true')
        query=query.replace("SELECT kind,ident,meta,encode(sha256(convert_to(meta::text,'UTF8')),'hex') sha256", "SELECT jsonb_build_object('kind',kind,'ident',ident,'meta',meta,'sha256',encode(sha256(convert_to(meta::text,'UTF8')),'hex'))")
        actual=[json.loads(line) for line in sql('office','BEGIN READ ONLY;'+query+'COMMIT;').stdout.splitlines() if line.startswith('{')]
        before={(r['kind'],r['ident']):semantic(r) for r in objects}
        after={(r['kind'],r['ident']):semantic(r) for r in actual}
        schema.require(before==after,'Native Office semantic baseline differs')
        detail.update(officeBaselineObjectCount=len(objects),officeSemanticCatalogEqual=True,
          officeNativeDumpSha256=hashlib.sha256((area/'office-current-application-schema.sql').read_bytes()).hexdigest())
        candidate=office_root/'supabase/migrations/20261101023410_office_first_pos_legal_connection.sql'
        sql('office',candidate.read_text())
        detail['officeCandidateMigrationSha256']=hashlib.sha256(candidate.read_bytes()).hexdigest()
        log=area/'pos-office-native-legal-tests.log'
        with log.open('w') as stream:
            log.chmod(0o600)
            result=unittest.TextTestRunner(stream=stream,verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(NativeCases))
        detail.update(count=result.testsRun,passed=max(0,result.testsRun-len(result.failures)-len(result.errors)-len(result.skipped)),
          failures=len(result.failures),errors=len(result.errors),skipped=len(result.skipped),
          casesLogSha256=hashlib.sha256(log.read_bytes()).hexdigest())
        schema.require(result.wasSuccessful() and result.testsRun==20 and not result.skipped,
                       'Native legal cases failed; inspect protected case log')
        return detail
    finally:
        diagnostics=''
        for argv in [['docker','inspect','--format','{{json .State}}',office_container],
                     ['docker','logs','--tail','200',office_container]]:
            r=cmd(argv,check=False);diagnostics+=r.stdout+'\n'+r.stderr+'\n'
        log=area/'pos-office-native-owned-office.log';log.write_text(diagnostics);log.chmod(0o600)
        detail['officeDiagnosticSha256']=hashlib.sha256(log.read_bytes()).hexdigest()
        detail['elapsedSeconds']=time.monotonic()-started
        detail['officeCleanupExitCode']=cmd(['docker','rm','-f',office_container],check=False).returncode
        receipt=area/'pos-office-native-legal-result.json'
        receipt.write_text(json.dumps(detail,indent=2)+'\n');receipt.chmod(0o600)
