"""Pinned real Realtime installer, owned DB and captured message authorization.

The application/Auth/Storage snapshot stays intact. Platform Realtime uses the
actual pinned self-host installer, not fabricated applied migration rows. The
captured production messages RLS is restored; never copy tenant secrets/events.
"""
import hashlib
import json
from pathlib import Path
import re
import secrets
import time
import urllib.error
import urllib.request

REALTIME_REF='public.ecr.aws/supabase/realtime:v2.143.3'
SOURCE_DIGEST='sha256:1591e9049bf15fd392da9e8344db892f6acfe9da274517327dbd14733f32b9e1'


def load_reference(platform,project,path):
    path=Path(path)
    raw=platform.schema.private.private_file(path,max_bytes=512*1024).read_bytes()
    row=json.loads(raw)
    platform.schema.require(row.get('kind')=='source-realtime-authorization-reference-only'
      and row.get('projectRef')==platform.schema.PROJECTS[project]
      and row.get('productionModified') is False and row.get('businessDataCollected') is False,
      'Realtime source scope differs')
    policies=row.get('policies');versions=row.get('migrationVersions');routines=row.get('routines')
    platform.schema.require(isinstance(policies,list) and len(policies)<=20
      and isinstance(versions,list) and 1<=len(versions)<=300
      and all(isinstance(v,str) and re.fullmatch(r'[0-9]{1,20}',v) for v in versions)
      and len(set(versions))==len(versions)
      and isinstance(routines,list) and 1<=len(routines)<=200,'Realtime reference is missing or oversized')
    names=[]
    for p in policies:
        platform.schema.require(set(p)=={'name','command','permissive','roles','using','check'}
          and isinstance(p['name'],str) and 1<=len(p['name'])<=128 and '\x00' not in p['name']
          and p['command'] in {'r','a','w','d','*'} and type(p['permissive']) is bool
          and isinstance(p['roles'],list) and 0<len(p['roles'])<=4
          and set(p['roles'])<={'PUBLIC','anon','authenticated','service_role'},'Realtime policy shape differs')
        for key in ['using','check']:
            platform.schema.require(p[key] is None or isinstance(p[key],str) and 0<len(p[key])<=65536
              and ';' not in p[key] and '\x00' not in p[key],'Invalid source policy expression')
        names.append(p['name'])
    platform.schema.require(len(names)==len(set(names)),'Duplicate Realtime source policy')
    for r in routines:
        platform.schema.require(set(r)=={'signature','definitionSha256'} and r['signature'].startswith('realtime.')
          and re.fullmatch(r'[a-f0-9]{64}',r['definitionSha256']),'Invalid source Realtime routine fingerprint')
    return row,hashlib.sha256(raw).hexdigest()


def preflight(platform,project,path):
    reference,digest=load_reference(platform,project,path)
    fixed=platform.runner.fixture_image.policy_for_ref(REALTIME_REF)
    platform.schema.require(fixed['sourceManifestDigest']==SOURCE_DIGEST,'Pinned Realtime source differs')
    actual=platform.runner.fixture_image.inspect_image([platform.real_docker],fixed['derivedImageId'])
    platform.runner.fixture_image.validate_image(actual,fixed)
    if not getattr(platform,'realtime_config_preflight_done',False):
        # Validate the actual release config without starting an app or DB.
        # The genuine startup below still runs migrations/seeds/its entrypoint.
        path=platform.output/'realtime-config-preflight.env'
        values=environment({'db':'127.0.0.1','password':'fixture-config-only','secret':'x'*64},
          'fixture-config','e'*16,'s'*128)
        path.write_text('\n'.join(k+'='+v for k,v in values.items())+'\n');path.chmod(0o600)
        platform.command('realtime-config-preflight',['docker','run','--rm','--name',platform.network+'-realtime-config-check','--network','none',
          '--memory','512m','--cpus','1','--env-file',str(path),'--entrypoint','/app/bin/realtime',
          REALTIME_REF,'eval',':ok'])
        platform.realtime_config_preflight_done=True
    platform.check(True,project+'-realtime-authorization-source-and-image-preflight')
    return reference,digest


def application_fingerprint(platform,project):
    query=Path(__file__).with_name('schema_export.sql').read_text().replace('/*SCOPE*/',
      ','.join(platform.schema.lit(n) for n in sorted(platform.manifests[project]['scope'])))
    query=query[:query.rindex('SELECT kind,ident,meta,encode')]+"SELECT coalesce(jsonb_agg(jsonb_build_array(kind,ident,encode(sha256(convert_to(meta::text,'UTF8')),'hex')) ORDER BY kind,ident),'[]'::jsonb) FROM objects;"
    # psql autocommit would otherwise ignore SET LOCAL and let a role default
    # search_path change dequalification/metadata text during comparison.
    rows=json.loads(platform.sql(project,'BEGIN;'+query+'COMMIT;').stdout)
    snapshots=platform.result.setdefault('realtimeApplicationFingerprints',{}).setdefault(project,[])
    path=platform.output/(project+'-realtime-application-catalog-'+str(len(snapshots))+'.json')
    from owned_platform import private_json
    private_json(path,rows)
    value=hashlib.sha256(platform.schema.runtime.pg_jsonb(rows).encode()).hexdigest()
    snapshots.append({'file':path.name,'sha256':value,'objects':len(rows)})
    return value


def identifier(value):return '"'+value.replace('"','""')+'"'


def restore_authorization(platform,project,reference):
    # Only this run's platform table, never production. Remove fixture defaults
    # before restoring the captured policy set; no extra permissive policy stays.
    sql="""DO $fixture$ DECLARE p record; BEGIN
 FOR p IN SELECT polname FROM pg_policy WHERE polrelid='realtime.messages'::regclass LOOP
  EXECUTE format('DROP POLICY %I ON realtime.messages',p.polname);
 END LOOP; END $fixture$;
 ALTER TABLE realtime.messages ENABLE ROW LEVEL SECURITY;
"""
    for p in reference['policies']:
        roles=','.join('PUBLIC' if r=='PUBLIC' else identifier(r) for r in p['roles'])
        sql+='CREATE POLICY '+identifier(p['name'])+' ON realtime.messages AS '+('PERMISSIVE' if p['permissive'] else 'RESTRICTIVE')
        sql+=' FOR '+{'r':'SELECT','a':'INSERT','w':'UPDATE','d':'DELETE','*':'ALL'}[p['command']]+' TO '+roles
        if p['using'] is not None:sql+=' USING ('+p['using']+')'
        if p['check'] is not None:sql+=' WITH CHECK ('+p['check']+')'
        sql+=';\n'
    platform.sql(project,sql)
    actual=json.loads(platform.sql(project,"""SELECT coalesce(jsonb_agg(jsonb_build_object(
 'name',p.polname,'command',p.polcmd,'permissive',p.polpermissive,
 'roles',(SELECT jsonb_agg(CASE WHEN r=0 THEN 'PUBLIC' ELSE pg_get_userbyid(r) END ORDER BY r) FROM unnest(p.polroles) r),
 'using',pg_get_expr(p.polqual,p.polrelid),'check',pg_get_expr(p.polwithcheck,p.polrelid)) ORDER BY p.polname),'[]'::jsonb)
 FROM pg_policy p WHERE p.polrelid='realtime.messages'::regclass;""").stdout)
    platform.check(actual==reference['policies'],project+'-realtime-message-authorization-exactly-restored')


def environment(config,tenant,encryption,secret_base):
    values={'APP_NAME':'realtime','PORT':'4000','DB_HOST':config['db'],'DB_PORT':'5432','DB_NAME':'postgres',
      'DB_AFTER_CONNECT_QUERY':'SET search_path TO _realtime',
      'DB_USER':'supabase_admin','DB_PASSWORD':config['password'],'DB_SSL':'false','DB_IP_VERSION':'ipv4',
      'DB_POOL_SIZE':'2','DB_REPLICA_POOL_SIZE':'2','DB_ENC_KEY':encryption,
      'SECRET_KEY_BASE':secret_base,'API_JWT_SECRET':config['secret'],'METRICS_JWT_SECRET':config['secret'],
      'SELF_HOST_TENANT_NAME':tenant,'SEED_SELF_HOST':'true','RUN_JANITOR':'false',
      'CLUSTER_STRATEGIES':'','REGION':'us-east-1','ERL_AFLAGS':'-proto_dist inet_tcp',
      'ERL_FLAGS':'+S 2:2 +A 2','BROADCAST_POOL_SIZE':'2','PRESENCE_POOL_SIZE':'2',
      'MIGRATION_PARTITION_SLOTS':'2','CONNECT_PARTITION_SLOTS':'2',
      'TENANT_MAX_CHANNELS_PER_CLIENT':'20','TENANT_MAX_CONCURRENT_USERS':'64',
      'WEBSOCKET_MAX_HEAP_SIZE':'8388608','TENANT_MAX_BYTES_PER_SECOND':'262144',
      'LOG_LEVEL':'warning','DISABLE_HEALTHCHECK_LOGGING':'true','METRICS_PUSHER_ENABLED':'false',
      'TENANT_METRICS_PUSHER_ENABLED':'false','OTEL_TRACES_EXPORTER':'none'}
    return values


def start(platform,project,reference_path):
    reference,reference_hash=load_reference(platform,project,reference_path)
    config=platform.projects[project];before=application_fingerprint(platform,project)
    platform.sql(project,'CREATE SCHEMA IF NOT EXISTS _realtime AUTHORIZATION supabase_admin;'
      'ALTER ROLE supabase_admin LOGIN PASSWORD '+platform.schema.lit(config['password'])+';')
    config['adminPassword']=config['password']
    encryption=secrets.token_hex(8);secret_base=secrets.token_hex(64)
    platform.redactions.extend([encryption,secret_base])
    name=platform.network+'-'+project+'-realtime';tenant='realtime-'+project
    config['realtime']=name;config['realtimeTenant']=tenant
    env_path=platform.output/(project+'-realtime.env')
    values=environment(config,tenant,encryption,secret_base)
    env_path.write_text('\n'.join(k+'='+v for k,v in values.items())+'\n');env_path.chmod(0o600)
    platform.command(project+'-realtime',['docker','run','-d','--name',name,'--network',platform.network,
      '--memory','512m','--cpus','1','--tmpfs','/tmp:rw,size=134217728',
      '--log-opt','max-size=10m','--log-opt','max-file=2','--env-file',str(env_path),REALTIME_REF])
    origin='http://'+platform.address(name)+':4000'
    opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
    for attempt in range(120):
        try:
            request=urllib.request.Request(origin+'/api/tenants/'+tenant+'/health',
              headers={'Authorization':'Bearer '+config['service']})
            with opener.open(request,timeout=1) as response:
                if response.status==200:
                    health=json.loads(response.read(64*1024));break
        except (OSError,urllib.error.URLError):pass
        if attempt%10==0 and not platform.container_running(name,'realtime-'+str(attempt)):
            raise RuntimeError('Actual Realtime exited before readiness; private diagnostics retained')
        time.sleep(.5)
    else:raise RuntimeError('Actual Realtime tenant health deadline reached')
    after=application_fingerprint(platform,project)
    platform.check(before==after,project+'-realtime-installer-preserves-application-auth-storage-catalog')
    restore_authorization(platform,project,reference)
    config['realtimeOrigin']=origin
    platform.gateways[project].websocket_target=origin
    platform.gateways[project].websocket_tenant=tenant
    platform.result['servicesPrepared'].append('real-'+project+'-realtime')
    if 'realtime' in platform.result['servicesNotPrepared']:
        platform.result['servicesNotPrepared'].remove('realtime')
        platform.result['servicesNotPrepared'].append(('office' if project=='pos' else 'pos')+'-realtime')
    elif project+'-realtime' in platform.result['servicesNotPrepared']:
        platform.result['servicesNotPrepared'].remove(project+'-realtime')
    fixed=platform.runner.fixture_image.policy_for_ref(REALTIME_REF)
    platform.result.setdefault('realtime',{})[project]={'sourceRef':fixed['sourceRef'],
      'derivedImageId':fixed['derivedImageId'],'sourceReferenceSha256':reference_hash,
      'sourceMessagePolicies':len(reference['policies']),'sourceRoutineFingerprints':reference['routines'],
      'productionMigrationVersionsCopied':False,'nativePinnedInstallerExecuted':True,
      'applicationAuthStorageCatalogUnchanged':True,'health':health,
      'memoryLimitBytes':512*1024*1024,'websocketHeapLimitBytes':8*1024*1024,
      'websocketExerciseComplete':False,'productionModified':False}
    platform.check(True,project+'-actual-realtime-tenant-is-healthy')
