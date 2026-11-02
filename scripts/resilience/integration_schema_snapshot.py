"""Owned isolated reconstruction experiment. No remote connections or data."""
import argparse
from datetime import datetime,timezone
from collections import Counter
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import time
import uuid

ROOT=Path(__file__).resolve().parents[2]
AREA=None
SOURCE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('schema_snapshot',SOURCE/'schema_snapshot.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)


def semantic(row):
    value=json.loads(json.dumps(row['meta']))
    owner=value.get('owner')
    if 'acl' in value:
        raw=value.pop('acl')
        if raw is None:
            codes={'schema':'UC','enum':'U','sequence':'rwU','relation':'arwdDxtm','routine':'X'}.get(row['kind'],'')
            default=[(owner,code,False,owner) for code in codes]
            if row['kind'] in ('routine','enum'):
                default.append(('PUBLIC','X' if row['kind']=='routine' else 'U',False,owner))
        else:default=m.acl_rows(raw)
        value['effectiveAcl']=sorted((g,c,False if g==owner else o,grantor) for g,c,o,grantor in default)
    if row['kind']=='relation':
        if value['kind']=='v':
            # pg_get_viewdef may add the default output alias on reparsing a
            # text literal in UNION branches. Only that redundant default alias
            # is normalized; source output-column names are compared separately.
            value['definition']=re.sub(r"(?m)^(\s*'(?:[^'\n]|'')*'::text) AS text(,?\s*)$",r'\1\2',value['definition'])
        for i,col in enumerate(value['columns'],1):
            col['position']=i
            col['acl']=sorted(m.acl_rows(col['acl']))
    for key in ['dependencies','roles']:
        if key in value:value[key]=sorted(value[key])
    return value


def run(name,native=False,candidate=False,office_root=None,exercise_transactions=False,exercise_payment_receipts=False,exercise_legal_connection=False):
    import os,shutil
    m.require(bool(os.environ.get('POS_LOCAL_RUN_ID')) and
      Path(shutil.which('docker') or '').resolve()==(ROOT/'scripts/local_verification/docker').resolve(),
      'Use the official isolated POS Docker ownership shim and run ID')
    if candidate and name=='office':
        m.require(office_root is not None and Path(office_root).is_absolute()
                  and (Path(office_root)/'supabase/migrations/20261101023410_office_first_pos_legal_connection.sql').is_file(),
                  'Preflight: Office source root and candidate migration are required')
    m.require(not exercise_transactions or name=='pos' and candidate,
              'Existing-transaction exercise requires POS candidate upgrade')
    m.require(not exercise_payment_receipts or name=='pos' and candidate and exercise_transactions,
              'Payment receipt exercise requires the POS native existing-transaction fixture')
    m.require(not exercise_legal_connection or name=='pos' and native and candidate
              and not exercise_transactions and office_root is not None,
              'Native legal exercise requires fresh POS candidate and explicit Office source')
    manifest,objects=m.load(name,AREA)
    m.inventory_guards(name,AREA)
    m.reference_sql(name,AREA)
    if native:m.private.private_file(AREA/(name+'-current-application-schema.sql'),max_bytes=m.MAX_BYTES)
    if not native:m.assemble(name,AREA)
    container='pos-resilience-schema-'+name+'-'+uuid.uuid4().hex[:12]
    report={'kind':'schema-reconstruction-experiment','projectRef':manifest['projectRef'],
            'scope':manifest['scope'],'network':'none','sourceObjectCount':len(objects),
            'nativeDumpValidated':False,'productionSchemaChanged':False,'businessDataCollected':False,
            'semanticNormalization':'ACL sets, visible column order and redundant text-literal default view aliases only; every other field compared'}
    if native:report['kind']='native-schema-dump-independent-roundtrip'
    report['runId']=os.environ['POS_LOCAL_RUN_ID']
    report['startedAt']=datetime.now(timezone.utc).isoformat()
    report['toolSha256']={p.name:hashlib.sha256(p.read_bytes()).hexdigest()
                         for p in [SOURCE/'schema_snapshot.py',SOURCE/'integration_schema_snapshot.py',SOURCE/'schema_export.sql']}
    report['manifestSha256']=hashlib.sha256((AREA/(name+'-manifest.json')).read_bytes()).hexdigest()
    report['sourceSha']=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
    report['workingTreeChangesPresent']=bool(subprocess.check_output(['git','status','--porcelain'],cwd=ROOT,text=True))
    def cmd(argv,body=None,check=True,timeout=120):
        p=subprocess.run(argv,input=body,text=True,capture_output=True,timeout=timeout)
        if check and p.returncode:
            log=AREA/(name+'-restore-error.log');log.write_text(p.stdout+'\n'+p.stderr);log.chmod(0o600)
            lines=[line for line in p.stderr.splitlines() if 'ERROR:' in line]
            print('isolated schema step failed; inspect the protected error log',flush=True)
            raise RuntimeError('Owned schema reconstruction failed; protected log '+str(log))
        return p
    def sql(body,check=True):
        # The pinned Supabase image's supautils GRANT-hint hook segfaults on a
        # denied function (also in an empty, unchanged image). Disable only its
        # cosmetic hints at connection startup; retain all ACL/RLS checks and
        # prove an anonymous denied call below. No production setting changes.
        return cmd(['docker','exec','-i','--env','PGPASSWORD=fixture-only',
                    '--env','PGOPTIONS=-c supautils.hint_roles=',container,
                    'psql','-X','-qAt','-U','supabase_admin','-d','postgres','-v','ON_ERROR_STOP=1'],body,check)
    def business_fingerprint():
        # Fixed table set, one aggregate query; rows are synthetic in this owned
        # container. Never issue this query against either production database.
        tables=['orders','order_items','payments','inventory_items','inventory_transactions',
                'order_discounts','order_discount_lines','menu_discount_quantities','meinvoice_jobs']
        parts=["SELECT "+m.lit(table)+" AS name,count(*) AS rows,md5(coalesce(string_agg(digest,',' ORDER BY digest),'')) AS hash FROM (SELECT md5(to_jsonb(t)::text) digest FROM public."+m.q(table)+" t) x" for table in tables]
        result=sql('SELECT jsonb_agg(x ORDER BY name) FROM ('+' UNION ALL '.join(parts)+') x;')
        return json.loads(result.stdout.strip())
    started=time.monotonic()
    try:
        cmd(['docker','run','--detach','--rm','--network','none','--memory','2g','--cpus','2',
             '--name',container,'--env','POSTGRES_PASSWORD=fixture-only',
             'public.ecr.aws/supabase/postgres:17.6.1.104'])
        for _ in range(60):
            if cmd(['docker','exec',container,'pg_isready','-h','127.0.0.1','-U','postgres'],check=False).returncode==0:break
            time.sleep(.5)
        else:raise RuntimeError('Owned schema fixture was not ready')
        probe=sql("BEGIN;CREATE FUNCTION public._pos_fixture_acl_probe() RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$ BEGIN RETURN 1; END $$;REVOKE ALL ON FUNCTION public._pos_fixture_acl_probe() FROM PUBLIC,anon;SET LOCAL ROLE anon;SELECT public._pos_fixture_acl_probe();",check=False)
        m.require(probe.returncode==3 and 'permission denied for function _pos_fixture_acl_probe' in probe.stderr,
                  'Pinned fixture must reject anonymous function execution without crashing')
        m.require(sql("SELECT current_setting('supautils.hint_roles');").stdout.strip()=='',
                  'Pinned fixture hint-only startup configuration was not applied')
        report['fixturePermissionErrorHintsDisabled']=True
        report['anonymousFunctionAclProbeRejected']=True
        if native:
            source=AREA/(name+'-current-application-schema.sql')
            stream=m.native_restore_sql(name,AREA)
            report['nativeDumpSha256']=hashlib.sha256(source.read_bytes()).hexdigest()
            report['nativeDumpBytesPreserved']=True
            report['bootstrapInsertion']='source extension prerequisites after native schema creation; original dump bytes retain order'
            result=sql(stream)
        else:result=sql((AREA/(name+'-reconstructed.sql')).read_text())
        if native:
            references=m.reference_sql(name,AREA)
            if references:
                sql(references)
                report['storageReferenceConfigSha256']=hashlib.sha256((AREA/(name+'-storage-reference-config.json')).read_bytes()).hexdigest()
        (AREA/(name+'-restore.log')).write_text(result.stderr)
        print(name,'schema DDL restored; comparing catalog',flush=True)
        query=(SOURCE/'schema_export.sql').read_text().replace('/*SCOPE*/',','.join(map(m.lit,manifest['scope']))).replace('/*PAGE*/','true')
        query=query.replace("SELECT kind,ident,meta,encode(sha256(convert_to(meta::text,'UTF8')),'hex') sha256", "SELECT jsonb_build_object('kind',kind,'ident',ident,'meta',meta,'sha256',encode(sha256(convert_to(meta::text,'UTF8')),'hex'))")
        result=sql('BEGIN READ ONLY;\n'+query+'\nCOMMIT;')
        actual=[json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
        (AREA/(name+'-restored-catalog.json')).write_text(json.dumps(actual))
        before={(r['kind'],r['ident']):semantic(r) for r in objects}
        after={(r['kind'],r['ident']):semantic(r) for r in actual}
        missing=sorted(before.keys()-after.keys());extra=sorted(after.keys()-before.keys())
        changed=[{'kind':k[0],'ident':k[1],'fields':[field for field in before[k].keys()|after[k].keys()
                     if before[k].get(field)!=after[k].get(field)]} for k in sorted(before.keys() & after.keys()) if before[k]!=after[k]]
        report.update({'missing':missing,'extra':extra,'changed':changed,'restoredObjectCount':len(actual),
                       'semanticCatalogEqual':not(missing or extra or changed)})
        print(name,'missing',len(missing),'extra',len(extra),'changed',len(changed),flush=True)
        if missing or extra or changed:raise RuntimeError('Restored semantic catalog differs; no PASS evidence')
        if native:
            report['nativeDumpValidated']=True
            if not candidate:return
            report['candidateUpgrade']=[]
            if exercise_transactions:
                setup=(ROOT/'test/fixtures/store_operating_upgrade_setup.sql').read_text()
                scenario=(ROOT/'test/sql/store_operating_payment_stock_test.sql').read_text()
                m.require(scenario.rstrip().endswith('ROLLBACK;'),'Reviewed stock scenario transaction boundary changed')
                sql(setup)
                sql("UPDATE public.store_lifecycle SET state='active',legacy_operational=true; ALTER TABLE public.orders DISABLE TRIGGER store_capture_sale_identity;")
                # Retain the reviewed successful 500-line transaction as legacy
                # history for the upgrade. The unchanged original scenario is
                # executed again with its rollback after the new migrations.
                retained=scenario.replace('Fixture ingredient 1','Fixture ingredient 1 before upgrade')
                retained=retained.replace('Fixture ingredient 2','Fixture ingredient 2 before upgrade')
                retained=retained.replace('Stock fixture','Stock fixture before upgrade').replace('Món thử kho','Món thử kho trước nâng cấp')
                sql(retained.rstrip()[:-len('ROLLBACK;')]+'COMMIT;')
                before_business=business_fingerprint()
                report['syntheticBusinessRowsCreated']=True
                report['beforeUpgradeBusinessFingerprint']=before_business
                report['stockScenarioSha256']=hashlib.sha256((ROOT/'test/sql/store_operating_payment_stock_test.sql').read_bytes()).hexdigest()
                report['retainedFixtureTransform']='Distinct synthetic ingredient/menu labels and final COMMIT only; original post-upgrade scenario unchanged'
            target=ROOT if name=='pos' else office_root
            m.require(target is not None and Path(target).is_absolute(),'Office source root is required')
            native_query="SELECT jsonb_object_agg(p.oid::regprocedure::text,md5(pg_get_functiondef(p.oid))) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname IN('process_payment','process_combined_table_payment','process_non_revenue_payment','process_payment_before_promotion_read_split','process_payment_without_scoped_promotions');"
            if name=='pos':native_before=json.loads(sql(native_query).stdout)
            versions=m.CANDIDATE_MIGRATIONS[name]
            for filename in versions:
                path=Path(target)/'supabase/migrations'/filename
                m.require(path.is_file() and not path.is_symlink(),'Missing candidate migration source')
                body=path.read_text()
                sql(body)
                report['candidateUpgrade'].append({'path':'supabase/migrations/'+filename,
                    'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'status':'APPLIED_TO_OWNED_FIXTURE_ONLY'})
            report['candidateMigrationSelfChecksPassed']=True
            if name=='pos':
                native_after=json.loads(sql(native_query).stdout)
                m.require(native_before==native_after,'Candidate migrations modified existing native payment functions')
                report['nativePaymentFunctionsUnchanged']=True
                report['nativePaymentFunctionHashes']=native_before
            if exercise_transactions:
                after_business=business_fingerprint()
                report['afterUpgradeBusinessFingerprint']=after_business
                m.require(before_business==after_business,'Upgrade changed existing financial/quantity/history rows')
                report['existingBusinessRowsPreserved']=True
                sql(scenario)
                report['postUpgradePaymentStockScenarioPassed']=True
            if exercise_payment_receipts:
                from payment_receipt_fixture import run as run_payment_receipts
                report['paymentCommandReceiptScenario']=run_payment_receipts(sql)
                from payment_command_v2_fixture import run as run_payment_v2
                report['paymentCommandV2Scenario']=run_payment_v2(sql)
            if exercise_legal_connection:
                from legal_connection_native_fixture import run as run_native_legal
                report['nativeLegalConnectionScenario']=run_native_legal(container,cmd,m,semantic,AREA,Path(office_root))
            return
        # Native dump is a separate, canonical-format serialization for existing
        # repository restore/upgrade tests; no production row has been copied.
        argv=['docker','exec','--env','PGPASSWORD=fixture-only',container,'pg_dump','-U','supabase_admin',
              '-d','postgres','--schema-only']
        for schema in manifest['scope']:argv.extend(['--schema',schema])
        dump=cmd(argv)
        output=AREA/(name+'-current-application-schema.sql');output.write_text(dump.stdout);output.chmod(0o600)
        report['nativeDumpSha256']=hashlib.sha256(output.read_bytes()).hexdigest()
        report['nativeDumpPath']=str(output)
        report['nativeDumpCreated']=True
        # A subsequent independent restore is still required, not implied here.
    finally:
        # Keep owned PostgreSQL crash/OOM evidence before --rm destroys it.
        # Logs may contain private source SQL: never print them to the console.
        diagnostics=[]
        for argv in [
            ['docker','inspect','--format','{{json .State}}',container],
            ['docker','logs','--tail','200',container],
        ]:
            detail=cmd(argv,check=False)
            diagnostics.append(detail.stdout+'\n'+detail.stderr)
        diagnostic_path=AREA/(name+'-owned-container-diagnostics.log')
        diagnostic_path.write_text('\n'.join(diagnostics));diagnostic_path.chmod(0o600)
        report['ownedContainerDiagnosticSha256']=hashlib.sha256(diagnostic_path.read_bytes()).hexdigest()
        cleanup=cmd(['docker','rm','-f',container],check=False)
        report['cleanupExitCode']=cleanup.returncode
        report['elapsedSeconds']=time.monotonic()-started
        report['finishedAt']=datetime.now(timezone.utc).isoformat()
        suffix=('-candidate-upgrade-report.json' if candidate else
                '-native-dump-roundtrip-report.json' if native else '-reconstruction-report.json')
        path=AREA/(name+suffix);path.write_text(json.dumps(report,indent=2)+'\n');path.chmod(0o600)
        for path in AREA.glob(name+'-*'):path.chmod(0o600)


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('name',choices=['pos','office']);p.add_argument('--snapshot-dir',type=Path,required=True)
    p.add_argument('--native-roundtrip',action='store_true')
    p.add_argument('--candidate-upgrade',action='store_true')
    p.add_argument('--office-root',type=Path)
    p.add_argument('--exercise-existing-transactions',action='store_true')
    p.add_argument('--exercise-payment-receipts',action='store_true')
    p.add_argument('--exercise-legal-connection',action='store_true')
    args=p.parse_args();AREA=args.snapshot_dir
    m.require(not args.candidate_upgrade or args.native_roundtrip,'Candidate upgrade requires native baseline roundtrip')
    run(args.name,args.native_roundtrip,args.candidate_upgrade,args.office_root,args.exercise_existing_transactions,args.exercise_payment_receipts,args.exercise_legal_connection)
