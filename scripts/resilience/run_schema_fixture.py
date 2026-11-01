"""Run a private schema rehearsal with owned fixtures and durable full logs."""
import argparse
from datetime import datetime,timezone
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import uuid

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'scripts/local_verification'))
import fixture_image


def now():return datetime.now(timezone.utc).isoformat()


def cleanup_owned(run_id,env):
    docker=next((p for p in ['/usr/bin/docker','/usr/local/bin/docker'] if Path(p).is_file()),None)
    if docker is None:return False
    prefix=[docker,'--host=unix:///var/run/docker.sock']
    for listing,remove in [(['ps','-aq'],['rm','-f']),(['network','ls','-q'],['network','rm'])]:
        query=prefix+listing+['--filter','label=pos.local.verification='+run_id]
        result=subprocess.run(query,env=env,text=True,capture_output=True,timeout=30)
        if result.returncode:return False
        ids=result.stdout.split()
        if ids:
            result=subprocess.run(prefix+remove+ids,env=env,capture_output=True,timeout=30)
            if result.returncode:return False
        result=subprocess.run(query,env=env,text=True,capture_output=True,timeout=30)
        if result.returncode or result.stdout.strip():return False
    return True


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('project',choices=['pos','office'])
    parser.add_argument('--snapshot-dir',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--native-roundtrip',action='store_true')
    parser.add_argument('--candidate-upgrade',action='store_true')
    parser.add_argument('--exercise-existing-transactions',action='store_true')
    parser.add_argument('--exercise-payment-receipts',action='store_true')
    parser.add_argument('--office-root',type=Path)
    args=parser.parse_args()
    spec=importlib.util.spec_from_file_location('schema_snapshot',Path(__file__).with_name('schema_snapshot.py'))
    schema=importlib.util.module_from_spec(spec);spec.loader.exec_module(schema)
    schema.load(args.project,args.snapshot_dir)
    schema.inventory_guards(args.project,args.snapshot_dir)
    schema.reference_sql(args.project,args.snapshot_dir)
    if args.native_roundtrip:
        schema.private.private_file(args.snapshot_dir/(args.project+'-current-application-schema.sql'),max_bytes=schema.MAX_BYTES)
    schema.require(args.output.is_absolute() and not args.output.is_symlink() and
                   not any((p/'.git').exists() for p in args.output.parents),'Output must be outside every Git worktree')
    schema.require(not args.candidate_upgrade or args.native_roundtrip,'Candidate mode requires native baseline')
    schema.require(not args.exercise_existing_transactions or args.project=='pos' and args.candidate_upgrade,
                   'Financial history exercise requires POS candidate mode')
    schema.require(not args.exercise_payment_receipts or args.project=='pos' and args.candidate_upgrade and args.exercise_existing_transactions,
                   'Payment receipt exercise requires native POS existing-transaction mode')
    if args.candidate_upgrade and args.project=='office':
        schema.require(args.office_root is not None and args.office_root.is_absolute() and
                       (args.office_root/'supabase/migrations/20261101023410_office_first_pos_legal_connection.sql').is_file(),
                       'Office candidate source is required before starting a fixture')
    lock_path=args.snapshot_dir/(args.project+'-fixture.lock')
    with open(lock_path,'a+') as lock:
        os.chmod(lock_path,0o600)
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        args.output.mkdir(parents=True,mode=0o700,exist_ok=False)
        run_id=uuid.uuid4().hex
        policy=fixture_image.policy()
        mapping={p['requestedRef']:p['derivedImageId'] for p in [policy,*policy.get('additionalImages',[])]}
        env=dict(os.environ)
        for key in ['DOCKER_HOST','DOCKER_CONTEXT','DOCKER_TLS','DOCKER_TLS_VERIFY','DOCKER_CERT_PATH']:env.pop(key,None)
        env.update(DOCKER_HOST='unix:///var/run/docker.sock',POS_LOCAL_RUN_ID=run_id,
                   POS_VERIFICATION_ARTIFACTS=str(args.output/'artifacts'),POS_FIXTURE_IMAGE_MAP=json.dumps(mapping))
        env['PATH']=str(ROOT/'scripts/local_verification')+os.pathsep+env['PATH']
        command=[sys.executable,'-B',str(Path(__file__).with_name('integration_schema_snapshot.py')),
                 args.project,'--snapshot-dir',str(args.snapshot_dir)]
        for flag in ['native_roundtrip','candidate_upgrade','exercise_existing_transactions','exercise_payment_receipts']:
            if getattr(args,flag):command.append('--'+flag.replace('_','-'))
        if args.office_root:command.extend(['--office-root',str(args.office_root)])
        record={'kind':'development-schema-rehearsal','runId':run_id,'startedAt':now(),
                'project':args.project,'command':command,'officialReleaseReceipt':False,
                'fullPlanComplete':False,'productionModified':False,'status':'RUNNING'}
        receipt=args.output/'result.json'
        def save():receipt.write_text(json.dumps(record,indent=2)+'\n');receipt.chmod(0o600)
        save();started=time.monotonic();child=None
        try:
            with open(args.output/'complete.log','x') as log:
                os.chmod(log.name,0o600)
                child=subprocess.Popen(command,env=env,stdout=log,stderr=subprocess.STDOUT,
                                       cwd=ROOT,start_new_session=True)
                try:record['exitCode']=child.wait(timeout=600)
                except subprocess.TimeoutExpired:
                    record['timedOut']=True
                    os.killpg(child.pid,signal.SIGINT)
                    try:child.wait(timeout=30)
                    except subprocess.TimeoutExpired:os.killpg(child.pid,signal.SIGKILL);child.wait()
                    record['exitCode']=child.returncode
            suffix=('-candidate-upgrade-report.json' if args.candidate_upgrade else
                    '-native-dump-roundtrip-report.json' if args.native_roundtrip else '-reconstruction-report.json')
            report_path=args.snapshot_dir/(args.project+suffix)
            if report_path.is_file():
                detail=json.loads(report_path.read_text())
                schema.require(detail.get('runId')==run_id and detail.get('projectRef')==schema.PROJECTS[args.project],
                               'Report belongs to another invocation/project')
                record['detail']=detail
                if detail.get('ownedContainerDiagnosticSha256'):
                    source=schema.private.private_file(args.snapshot_dir/(args.project+'-owned-container-diagnostics.log'),max_bytes=8*1024*1024)
                    content=source.read_bytes()
                    schema.require(hashlib.sha256(content).hexdigest()==detail['ownedContainerDiagnosticSha256'],
                                   'Owned container diagnostics changed after execution')
                    artifact=args.output/'owned-container-diagnostics.log'
                    artifact.write_bytes(content);artifact.chmod(0o600)
                    record['diagnostics']={'path':artifact.name,'sha256':detail['ownedContainerDiagnosticSha256']}
            valid=record.get('exitCode')==0 and record.get('detail',{}).get('semanticCatalogEqual') is True
            if args.native_roundtrip:valid=valid and record['detail'].get('nativeDumpValidated') is True
            if args.candidate_upgrade:valid=valid and record['detail'].get('candidateMigrationSelfChecksPassed') is True
            if args.exercise_existing_transactions:valid=valid and record['detail'].get('existingBusinessRowsPreserved') is True and record['detail'].get('postUpgradePaymentStockScenarioPassed') is True
            if args.exercise_payment_receipts:
                scenario=record['detail'].get('paymentCommandReceiptScenario',{})
                valid=valid and isinstance(scenario,dict) and scenario.get('count',0)>=22 and scenario.get('count')==len(set(scenario.get('checksPassed',[]))) and scenario.get('nativePaymentFunctionsStubbed') is False and scenario.get('fixtureSha256')==hashlib.sha256(Path(__file__).with_name('payment_receipt_fixture.py').read_bytes()).hexdigest()
            record['status']='PASS' if valid and not record.get('timedOut') else 'FAIL'
        except BaseException:
            record['status']='FAIL'
            if child is not None and child.poll() is None:
                os.killpg(child.pid,signal.SIGINT)
                try:child.wait(timeout=30)
                except subprocess.TimeoutExpired:os.killpg(child.pid,signal.SIGKILL);child.wait()
            raise
        finally:
            try:record['cleanupVerified']=cleanup_owned(run_id,env)
            except (OSError,subprocess.TimeoutExpired):record['cleanupVerified']=False
            if not record['cleanupVerified']:record['status']='FAIL'
            record['elapsedSeconds']=time.monotonic()-started;record['finishedAt']=now()
            log=args.output/'complete.log'
            if log.exists():record['completeLogSha256']=hashlib.sha256(log.read_bytes()).hexdigest()
            if record['status']=='RUNNING':record['status']='FAIL'
            save()
        print(json.dumps({'status':record['status'],'result':str(receipt),'runId':run_id}))
        return 0 if record['status']=='PASS' else 1


if __name__=='__main__':sys.exit(main())
