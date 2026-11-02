"""Owned native-schema / real GoTrue preflight, never a production executor.

No production credentials/users are copied. Uses a private data-free schema dump,
a pinned Auth service in serve-only mode, and one new synthetic Auth API user.
Private loopback/bridge HTTP is allowed only to this run's owned container.
This is environment preparation, not browser/workflow/soak/release evidence.
"""
import argparse,base64,hashlib,hmac,importlib.util,ipaddress,json,os,secrets,shutil,signal,subprocess,time,urllib.request,urllib.error,uuid
from datetime import datetime,timezone
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]

def run(project,snapshot_dir,output):
    root=ROOT;area=output
    snap=snapshot_dir;run=uuid.uuid4().hex;network='pos-auth-probe-'+run[:12];anchor=network+'-anchor';db=network+'-db';auth=network+'-auth'
    def module(name,p):
     s=importlib.util.spec_from_file_location(name,p);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
    schema=module('native_schema',root/'scripts/resilience/schema_snapshot.py');runner=module('schema_runner',root/'scripts/resilience/run_schema_fixture.py')
    schema.load(project,snap)
    restore=schema.native_restore_sql(project,snap)
    schema.require(area.is_absolute() and not area.is_symlink() and not any((p/'.git').exists() for p in area.parents),'Output must be outside every Git worktree')
    area.mkdir(mode=0o700,exist_ok=False)
    policy=runner.fixture_image.policy();mapping={p['requestedRef']:p['derivedImageId'] for p in [policy,*policy.get('additionalImages',[])]}
    env=dict(os.environ)
    for k in ['DOCKER_CONTEXT','DOCKER_TLS','DOCKER_TLS_VERIFY','DOCKER_CERT_PATH']:env.pop(k,None)
    env.update(DOCKER_HOST='unix:///var/run/docker.sock',POS_LOCAL_RUN_ID=run,POS_LOCAL_TOOL_CONTAINER=anchor,POS_VERIFICATION_ARTIFACTS=str(area/'artifacts'),POS_FIXTURE_IMAGE_MAP=json.dumps(mapping))
    env['PATH']=str(root/'scripts/local_verification')+':'+env['PATH'];real=shutil.which('docker',path=os.environ['PATH'])
    secret=secrets.token_urlsafe(48);password=secrets.token_urlsafe(32)
    record={'project':project,'kind':'owned-native-schema-real-auth-preflight','runId':run,'startedAt':datetime.now(timezone.utc).isoformat(),'status':'RUNNING','productionModified':False,'officialReleaseReceipt':False,'fullPlanComplete':False,'checks':[]}
    def save():
     p=area/'result.json';p.write_text(json.dumps(record,indent=2)+'\n');p.chmod(0o600)
    def step(name,argv,body=None,timeout=60,check=True):
     r=subprocess.run(argv,input=body,text=True,capture_output=True,env=env,cwd=root,timeout=timeout)
     p=area/(name+'.log');p.write_text((r.stdout+'\n'+r.stderr).replace(secret,'[REDACTED_FIXTURE_SECRET]').replace(password,'[REDACTED_FIXTURE_PASSWORD]'));p.chmod(0o600)
     record.setdefault('steps',[]).append({'name':name,'exitCode':r.returncode,'logSha256':hashlib.sha256(p.read_bytes()).hexdigest()});save()
     if check and r.returncode:raise RuntimeError('Protected preflight failure: '+name)
     return r
    seq=0
    def sql(body,check=True):
     nonlocal seq
     seq+=1
     return step('sql-'+str(seq),['docker','exec','-i','--env','PGPASSWORD=fixture-only','--env','PGOPTIONS=-c supautils.hint_roles=',db,'psql','-X','-qAt','-U','supabase_admin','-d','postgres','-v','ON_ERROR_STOP=1'],body,120,check)
    def b64(data):return base64.urlsafe_b64encode(data).decode().rstrip('=')
    def jwt(role):
     now=int(time.time());v=b64(json.dumps({'alg':'HS256','typ':'JWT'},separators=(',',':')).encode())+'.'+b64(json.dumps({'role':role,'aud':'authenticated','iss':'supabase','iat':now,'exp':now+3600},separators=(',',':')).encode());return v+'.'+b64(hmac.new(secret.encode(),v.encode(),hashlib.sha256).digest())
    http=urllib.request.build_opener(urllib.request.ProxyHandler({}))
    def request(path,body=None,token=None):
     data=json.dumps(body).encode() if body is not None else None
     headers={'content-type':'application/json'}
     if token:headers['Authorization']='Bearer '+token
     req=urllib.request.Request(origin+path,data=data,headers=headers)
     try:
      with http.open(req,timeout=10) as response:return response.status,json.loads(response.read())
     except urllib.error.HTTPError as e:
      payload=e.read();p=area/('http-error-'+str(len(record['checks']))+'.json');p.write_bytes(payload);p.chmod(0o600);return e.code,{}
    def check(ok,name):
     if not ok:raise RuntimeError('Native real Auth preflight failed: '+name)
     record['checks'].append(name);save();print('AUTH_PREFLIGHT='+name,flush=True)
    save();start=time.monotonic()
    try:
     record['sourceSha']=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip()
     record['workingTreeChangesPresent']=bool(subprocess.check_output(['git','status','--porcelain'],cwd=root,text=True))
     inputs=[Path(__file__),root/'scripts/resilience/schema_snapshot.py',root/'scripts/resilience/run_schema_fixture.py',root/'scripts/resilience/runtime_catalog.py',root/'scripts/resilience/sample_accounts.py',root/'scripts/local_verification/docker',root/'scripts/local_verification/fixture_image.py']
     before={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
     record['toolInputHashes']=before
     ref='public.ecr.aws/supabase/gotrue@sha256:c0c25187a6b835e65a6f6e6c6b39d090e832d40e6de5186f2c038e0411944232'
     image=json.loads(step('auth-image-preflight',[real,'image','inspect',ref]).stdout)[0]
     check(image['Os']=='linux' and image['Architecture']=='amd64' and ref in image['RepoDigests'] and image['Config']['Cmd']==['auth'],'pinned-auth-image-and-command')
     record['authImageId']=image['Id']
     record['authStartupMode']='serve subcommand, using restored Auth schema without running or fabricating migrations'
     record['schemaSha256']=hashlib.sha256((snap/(project+'-current-application-schema.sql')).read_bytes()).hexdigest()
     anchor_image=next(p['derivedImageId'] for p in policy['additionalImages'] if '17-alpine' in p['requestedRef'])
     step('network-anchor',[real,'run','-d','--name',anchor,'--label','pos.local.verification='+run,'--entrypoint','/bin/sh',anchor_image,'-c','exec sleep 600'])
     step('network',['docker','network','create',network])
     step('database',['docker','run','-d','--name',db,'--network',network,'--memory','2g','--cpus','2','--env','POSTGRES_PASSWORD=fixture-only','public.ecr.aws/supabase/postgres:17.6.1.104'])
     for i in range(60):
      r=subprocess.run(['docker','exec',db,'pg_isready','-h','127.0.0.1','-U','postgres'],env=env,capture_output=True)
      if r.returncode==0:break
      time.sleep(.5)
     else:raise RuntimeError('Owned DB unavailable')
     sql(restore);check(True,'native-project-schema-restored')
     sql("ALTER ROLE supabase_auth_admin PASSWORD '"+password+"';")
     authenv=area/'auth.env';authenv.write_text('\n'.join([
      'GOTRUE_API_HOST=0.0.0.0','GOTRUE_API_PORT=9999','API_EXTERNAL_URL=http://'+auth+':9999',
      'GOTRUE_DB_DRIVER=postgres','GOTRUE_DB_DATABASE_URL=postgres://supabase_auth_admin:'+password+'@'+db+':5432/postgres',
      'GOTRUE_SITE_URL=http://127.0.0.1','GOTRUE_JWT_SECRET='+secret,'GOTRUE_JWT_EXP=3600',
      'GOTRUE_JWT_AUD=authenticated','GOTRUE_JWT_ADMIN_ROLES=service_role','GOTRUE_JWT_DEFAULT_GROUP_NAME=authenticated',
      'GOTRUE_EXTERNAL_EMAIL_ENABLED=true','GOTRUE_MAILER_AUTOCONFIRM=true','GOTRUE_DISABLE_SIGNUP=false',
      'GOTRUE_DB_MAX_POOL_SIZE=4','GOTRUE_LOG_LEVEL=warn'])+'\n');authenv.chmod(0o600)
     ref='public.ecr.aws/supabase/gotrue@sha256:c0c25187a6b835e65a6f6e6c6b39d090e832d40e6de5186f2c038e0411944232'
     record['authImage']=ref
     step('auth',['docker','run','-d','--name',auth,'--network',network,'--memory','256m','--cpus','1','--env-file',str(authenv),'--entrypoint','auth',ref,'serve'])
     info=json.loads(step('auth-address',['docker','inspect','--format','{{json .NetworkSettings.Networks}}',auth]).stdout)
     address=info[network]['IPAddress'];check(ipaddress.ip_address(address).is_private,'owned-private-auth-address')
     origin='http://'+address+':9999'
     for i in range(60):
      try:
       status,health=request('/health')
       if status==200:break
      except (OSError,urllib.error.URLError):pass
      time.sleep(.5)
     else:raise RuntimeError('Owned Auth service not ready')
     check(status==200,'real-gotrue-health')
     status,user=request('/admin/users',{'email':'native-auth-probe@fixture.invalid','password':password,'email_confirm':True},jwt('service_role'))
     check(status in [200,201] and isinstance(user.get('id'),str),'auth-admin-api-created-synthetic-user')
     status,session=request('/token?grant_type=password',{'email':'native-auth-probe@fixture.invalid','password':password})
     check(status==200 and session.get('user',{}).get('id')==user['id'] and bool(session.get('access_token')),'real-password-login')
     status,refreshed=request('/token?grant_type=refresh_token',{'refresh_token':session['refresh_token']})
     check(status==200 and refreshed.get('user',{}).get('id')==user['id'],'real-session-refresh')
     check(sql('SELECT count(*) FROM auth.users;').stdout.strip()=='1','only-one-synthetic-auth-user')
     check(before=={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs},'tool-inputs-unchanged')
     record['status']='PASS'
    except BaseException as e:
     record['status']='FAIL';record['failureType']=type(e).__name__;record['failure']=str(e);raise
    finally:
     try:
      for name in [auth,db]:
       step('diagnostics-'+name,['docker','logs','--tail','100',name],check=False)
     except (OSError,subprocess.TimeoutExpired) as error:
      record['diagnosticFailureType']=type(error).__name__;record['status']='FAIL'
     finally:
      try:record['cleanupVerified']=runner.cleanup_owned(run,env)
      except (OSError,subprocess.TimeoutExpired):record['cleanupVerified']=False
     if not record['cleanupVerified']:record['status']='FAIL'
     record['elapsedSeconds']=time.monotonic()-start;record['finishedAt']=datetime.now(timezone.utc).isoformat();save()
     print(json.dumps({k:record.get(k) for k in ['status','cleanupVerified','elapsedSeconds','failureType']}),flush=True)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('project',choices=['pos','office'])
    parser.add_argument('--snapshot-dir',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    def terminate(_signum,_frame):raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM,terminate)
    spec=importlib.util.spec_from_file_location('auth_fixture_runner',ROOT/'scripts/resilience/run_schema_fixture.py')
    runner=importlib.util.module_from_spec(spec);spec.loader.exec_module(runner)
    with runner.fixture_locks(args.snapshot_dir,[args.project]):
        run(args.project,args.snapshot_dir,args.output)
    receipt=json.loads((args.output/'result.json').read_text())
    return 0 if receipt['status']=='PASS' else 1


if __name__=='__main__':raise SystemExit(main())
