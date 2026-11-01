"""Real pinned Storage API over the unchanged native Storage schema.

Restore only captured platform migration reference metadata, never fabricated
applied rows. The source schema fingerprint must match the private snapshot.
"""
import hashlib
import ipaddress
import json
from pathlib import Path
import re
import time
import urllib.error
import urllib.request

STORAGE_REF='public.ecr.aws/supabase/storage-api:v1.81.0'
SOURCE_DIGEST='sha256:98ffec5d0678803783c30e404c27f4ec65e97efbe014088f2a86b4b8b54b9f54'


def preflight(platform,project,path):
    reference,digest=load_reference(platform,project,path)
    fixed=platform.runner.fixture_image.policy_for_ref(STORAGE_REF)
    platform.schema.require(fixed['sourceManifestDigest']==SOURCE_DIGEST,'Pinned Storage source differs')
    image=platform.runner.fixture_image.inspect_image([platform.real_docker],fixed['derivedImageId'])
    platform.runner.fixture_image.validate_image(image,fixed)
    platform.check(True,project+'-storage-source-reference-and-image-preflight')
    return reference,digest


def validate_history_refresh(before,after):
    if not isinstance(after,list) or len(after)!=len(before):
        raise ValueError('Storage startup changed the applied migration set')
    changed=[]
    for original,current in zip(before,after):
        if set(current)!={'id','name','hash'} or current['id']!=original['id'] or current['name']!=original['name']:
            raise ValueError('Storage startup changed migration identities')
        if current['hash']!=original['hash']:
            if current['id'] not in {2,62} or not re.fullmatch(r'[a-fA-F0-9]{40}',str(current['hash'])):
                raise ValueError('Unreviewed Storage migration hash refresh')
            changed.append(current['id'])
    return changed


def load_reference(platform, project, path):
    path=Path(path)
    raw=platform.schema.private.private_file(path,max_bytes=128*1024).read_bytes()
    reference=json.loads(raw)
    platform.schema.require(reference.get('kind')=='source-storage-migration-reference-only'
      and reference.get('projectRef')==platform.schema.PROJECTS[project]
      and reference.get('productionModified') is False and reference.get('businessDataCollected') is False,
      'Storage reference project/source metadata mismatch')
    _,objects=platform.schema.load(project,platform.snapshot)
    rows=[[r['kind'],r['ident'],r['sha256']] for r in objects if r['ident']=='storage' or r['ident'].startswith('storage.')]
    fingerprint=hashlib.sha256(platform.schema.runtime.pg_jsonb(rows).encode()).hexdigest()
    platform.schema.require(reference.get('sourceFingerprint')=={'storage_schema_sha256':fingerprint,'object_count':len(rows)},
      'Storage source reference differs from captured native schema')
    migrations=reference.get('migrations')
    platform.schema.require(isinstance(migrations,list) and 0<len(migrations)<=200,
      'Storage migration reference is missing or oversized')
    for r in migrations:
        platform.schema.require(set(r)=={'id','name','hash'} and type(r['id']) is int and 0<=r['id']<1000
          and isinstance(r['name'],str) and re.fullmatch(r'[a-zA-Z0-9_.-]{1,160}',r['name'])
          and isinstance(r['hash'],str) and re.fullmatch(r'[a-fA-F0-9]{40}',r['hash']),
          'Storage migration reference shape is invalid')
    platform.schema.require(len({r['id'] for r in migrations})==len(migrations)
      and len({r['name'] for r in migrations})==len(migrations)
      and migrations==sorted(migrations,key=lambda r:r['id'])
      and [r['id'] for r in migrations]==list(range(74))
      and migrations[-1]['id']==73 and migrations[-1]['name']=='revoke-grants-to-unused-operations',
      'Storage reference is incompatible with the inspected image/freeze point')
    return reference,hashlib.sha256(raw).hexdigest()


def fingerprint(platform,project):
    scope=platform.manifests[project]['scope']
    query=(Path(__file__).with_name('schema_export.sql')).read_text().replace('/*SCOPE*/',','.join(platform.schema.lit(n) for n in scope))
    query=query[:query.rindex('SELECT kind,ident,meta,encode')]+"SELECT encode(sha256(convert_to(coalesce(jsonb_agg(jsonb_build_array(kind,ident,encode(sha256(convert_to(meta::text,'UTF8')),'hex')) ORDER BY kind,ident),'[]'::jsonb)::text,'UTF8')),'hex') FROM objects WHERE ident='storage' OR ident LIKE 'storage.%';"
    return platform.sql(project,query).stdout.strip()


def start(platform,project,reference_path):
    reference,reference_hash=load_reference(platform,project,reference_path)
    config=platform.projects[project]
    before=fingerprint(platform,project)
    # Native schema/history equality is established above. These are exact
    # captured platform rows, not an invented success for candidate migrations.
    platform.sql(project,"INSERT INTO storage.migrations(id,name,hash) SELECT id,name,hash FROM jsonb_to_recordset("+
      platform.schema.lit(json.dumps(reference['migrations']))+'::jsonb) AS r(id integer,name text,hash text);'+
      'ALTER ROLE supabase_storage_admin LOGIN PASSWORD '+platform.schema.lit(config['password'])+';')
    restored=json.loads(platform.sql(project,'SELECT jsonb_agg(jsonb_build_object(\'id\',id,\'name\',name,\'hash\',hash) ORDER BY id) FROM storage.migrations;').stdout)
    platform.check(restored==reference['migrations'],project+'-actual-storage-reference-history-restored')
    fixed=platform.runner.fixture_image.policy_for_ref(STORAGE_REF)
    platform.schema.require(fixed['sourceManifestDigest']==SOURCE_DIGEST,'Pinned Storage source differs')
    image=platform.runner.fixture_image.inspect_image([platform.real_docker],fixed['derivedImageId'])
    platform.runner.fixture_image.validate_image(image,fixed)
    storage=platform.network+'-'+project+'-storage'
    config['storage']=storage
    storage_env=platform.output/(project+'-storage.env')
    values={'SERVER_HOST':'0.0.0.0','SERVER_PORT':'5000','ANON_KEY':config['anon'],
      'SERVICE_KEY':config['service'],'PGRST_JWT_SECRET':config['secret'],
      'DATABASE_URL':'postgres://supabase_storage_admin:'+config['password']+'@'+config['db']+':5432/postgres?options=-c%20supautils.hint_roles%3D',
      # Upstream's supported hash-only refresh handles amended historical files.
      # Original source rows remain in the private reference; no migration ID
      # may be added/relabelled, and the native schema fingerprint must not change.
      'DB_INSTALL_ROLES':'false','DB_ALLOW_MIGRATION_REFRESH':'true',
      'DB_MIGRATIONS_FREEZE_AT':'revoke-grants-to-unused-operations','DATABASE_MAX_CONNECTIONS':'4',
      'STORAGE_BACKEND':'file','FILE_STORAGE_BACKEND_PATH':'/var/lib/storage',
      'FILE_SIZE_LIMIT':'5242880','PG_QUEUE_ENABLE':'false','TENANT_ID':'fixture-'+project,
      'WORKERS_NUM':'1','STORAGE_VERSIONING_ENABLED':'false',
      'REGION':'local','LOG_LEVEL':'warn','NODE_OPTIONS':'--max-old-space-size=384'}
    storage_env.write_text('\n'.join(k+'='+v for k,v in values.items())+'\n');storage_env.chmod(0o600)
    platform.command(project+'-storage',['docker','run','-d','--name',storage,'--network',platform.network,
      '--memory','768m','--cpus','1','--tmpfs','/var/lib/storage:rw,size=268435456',
      '--env-file',str(storage_env),STORAGE_REF])
    address=platform.address(storage)
    platform.schema.require(ipaddress.ip_address(address).is_private,'Storage must be an owned private service')
    origin='http://'+address+':5000'
    for attempt in range(100):
        try:
            opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
            with opener.open(origin+'/status',timeout=1) as response:
                if response.status==200:break
        except (OSError,urllib.error.URLError):pass
        if attempt%10==0 and not platform.container_running(storage,'storage-'+str(attempt)):
            raise RuntimeError('Actual Storage exited before readiness; private diagnostics retained')
        time.sleep(.5)
    else:raise RuntimeError('Actual Storage readiness timed out; private diagnostics retained')
    after=fingerprint(platform,project)
    platform.check(before==after,project+'-storage-startup-did-not-change-native-schema')
    history=json.loads(platform.sql(project,'SELECT jsonb_agg(jsonb_build_object(\'id\',id,\'name\',name,\'hash\',hash) ORDER BY id) FROM storage.migrations;').stdout)
    refreshed=validate_history_refresh(reference['migrations'],history)
    platform.check(True,project+'-storage-startup-only-refreshed-reviewed-historical-hashes')
    platform.gateways[project].targets['storage']=origin
    platform.result['servicesPrepared'].append('real-'+project+'-storage')
    if 'storage' in platform.result['servicesNotPrepared']:
        platform.result['servicesNotPrepared'].remove('storage')
        platform.result['servicesNotPrepared'].append(('office' if project=='pos' else 'pos')+'-storage')
    else:
        other=project+'-storage'
        if other in platform.result['servicesNotPrepared']:platform.result['servicesNotPrepared'].remove(other)
    platform.result.setdefault('storage',{})[project]={'sourceRef':fixed['sourceRef'],
      'derivedImageId':image['Id'],'nativeSchemaUnchanged':True,'sourceReferenceSha256':reference_hash,
      'sourceSchemaFingerprint':reference['sourceFingerprint'],'sourceMigrationRowsRestored':len(restored),
      'migrationFreezeAt':'revoke-grants-to-unused-operations','filesystemBytesLimit':268435456,
      'historicalHashOnlyRefreshIds':refreshed,
      'connectionPoolLimit':4,'memoryLimitBytes':768*1024*1024,'productionModified':False}
    platform.check(True,project+'-real-storage-api-ready')
