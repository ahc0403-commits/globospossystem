"""Independent native DB + real Auth + JWT/RLS REST for POS and Office.

All credentials are freshly generated and private. This prepares only the
services listed in the result; absent Storage/Realtime is never reported ready.
"""
import base64
import hashlib
import hmac
import importlib.util
import ipaddress
import json
import os
from pathlib import Path
import secrets
import subprocess
import threading
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
AUTH_IMAGE = 'public.ecr.aws/supabase/gotrue@sha256:c0c25187a6b835e65a6f6e6c6b39d090e832d40e6de5186f2c038e0411944232'
REST_IMAGE = 'public.ecr.aws/supabase/postgrest@sha256:b574528fe109c8343c1247155734d03df8c34b462f342dca0ccc20244fc36ef9'


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


def private_json(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')
    path.chmod(0o600)


def literal(value):
    return "'" + str(value).replace("'", "''") + "'"


class OwnedPlatform:
    def __init__(self, snapshot, office_root, output, projects=('pos','office')):
        self.schema = module('platform_schema', HERE / 'schema_snapshot.py')
        self.runner = module('platform_runner', HERE / 'run_schema_fixture.py')
        self.gateway_module = module('platform_gateway', HERE / 'runtime_gateway.py')
        self.selected_projects=tuple(projects)
        self.schema.require(bool(self.selected_projects) and len(set(self.selected_projects))==len(self.selected_projects)
          and set(self.selected_projects)<={'pos','office'},'Explicit nonempty fixture project selection required')
        self.snapshot, self.office_root, self.output = map(Path, (snapshot, office_root, output))
        self.schema.require(self.output.is_absolute() and not self.output.is_symlink()
          and not any((p / '.git').exists() for p in self.output.parents),
          'Private runtime output must be outside every Git worktree')
        self.schema.require(self.office_root.is_absolute() and (self.office_root / 'supabase/functions/pos-bridge/index.ts').is_file(),
          'Explicit Office checkout is required')
        self.manifests, self.restores = {}, {}
        for project in self.selected_projects:
            self.manifests[project], _ = self.schema.load(project, self.snapshot)
            self.schema.inventory_guards(project, self.snapshot)
            self.restores[project] = self.schema.native_restore_sql(project, self.snapshot)
        self.output.mkdir(mode=0o700, exist_ok=False)
        self.run_id = uuid.uuid4().hex
        self.network = 'pos-runtime-' + self.run_id[:12]
        self.anchor = self.network + '-anchor'
        self.real_docker = next((p for p in ('/usr/bin/docker','/usr/local/bin/docker')
          if os.path.isfile(p) and os.access(p,os.X_OK)), None)
        self.schema.require(self.real_docker is not None, 'System Docker binary is required')
        self.env = dict(os.environ)
        for key in ('DOCKER_CONTEXT', 'DOCKER_TLS', 'DOCKER_TLS_VERIFY', 'DOCKER_CERT_PATH'):
            self.env.pop(key, None)
        policy = self.runner.fixture_image.policy()
        self.policy = policy
        self.env.update(DOCKER_HOST='unix:///var/run/docker.sock', POS_LOCAL_RUN_ID=self.run_id,
          POS_LOCAL_TOOL_CONTAINER=self.anchor, POS_VERIFICATION_ARTIFACTS=str(self.output / 'artifacts'),
          POS_FIXTURE_IMAGE_MAP=json.dumps({p['requestedRef']:p['derivedImageId'] for p in [policy, *policy.get('additionalImages', [])]}))
        self.env['PATH'] = str(ROOT / 'scripts/local_verification') + ':' + self.env['PATH']
        self.projects, self.gateways, self.threads, self.processes = {}, {}, [], []
        self.sequence, self.redactions = 0, []
        self.result = {'kind':'owned-native-auth-rest-runtime', 'runId':self.run_id,
          'projectScopes':list(self.selected_projects),'independentProjectCount':len(self.selected_projects),
          'startedAt':datetime.now(timezone.utc).isoformat(), 'status':'RUNNING',
          'productionModified':False, 'productionCredentialsCopied':False,
          'officialReleaseReceipt':False, 'fullPlanComplete':False,
          'servicesPrepared':[], 'servicesNotPrepared':['storage','realtime','mail','printer'],
          'fixtureMaxLifetimeSeconds':129600,'fixtureApiKeyLifetimeSeconds':172800,
          'checks':[], 'migrations':{}, 'steps':[]}
        self.started = time.monotonic()
        self.save()

    def save(self):
        private_json(self.output / 'result.json', self.result)

    def check(self, condition, name):
        if not condition:
            raise RuntimeError('Owned runtime check failed: ' + name)
        self.result['checks'].append(name)
        self.save()
        print('RUNTIME_CHECK=' + name, flush=True)

    def command(self, name, argv, body=None, timeout=120, check=True):
        value = subprocess.run(argv, input=body, text=True, capture_output=True,
          env=self.env, cwd=ROOT, timeout=timeout)
        raw = value.stdout + '\n' + value.stderr
        for secret in self.redactions:
            raw = raw.replace(secret, '[REDACTED_FIXTURE_SECRET]')
        path = self.output / (name + '.log')
        path.write_text(raw)
        path.chmod(0o600)
        self.result['steps'].append({'name':name, 'exitCode':value.returncode,
          'logSha256':hashlib.sha256(path.read_bytes()).hexdigest(),
          'diskAvailableBytes':os.statvfs(self.output).f_bavail*os.statvfs(self.output).f_frsize})
        self.save()
        if check and value.returncode:
            raise RuntimeError('Owned runtime step failed: ' + name)
        return value

    def sql(self, project, body, check=True):
        self.sequence += 1
        return self.command('sql-' + str(self.sequence), ['docker','exec','-i',
          '--env','PGPASSWORD='+self.projects[project].get('adminPassword','fixture-only'),'--env','PGOPTIONS=-c supautils.hint_roles=',
          self.projects[project]['db'], 'psql','-X','-qAt','-U','supabase_admin','-d','postgres',
          '-v','ON_ERROR_STOP=1'], body, check=check)

    def address(self, name):
        value = json.loads(self.command('address-' + name,
          ['docker','inspect','--format','{{json .NetworkSettings.Networks}}',name]).stdout)
        address = value[self.network]['IPAddress']
        self.schema.require(ipaddress.ip_address(address).is_private, 'Only owned private addresses')
        return address

    def container_running(self,name,stage):
        value=self.command('container-state-'+stage,['docker','inspect','--format','{{.State.Running}}',name],check=False)
        return value.returncode==0 and value.stdout.strip()=='true'

    def jwt(self, project, role):
        def encode(value):
            return base64.urlsafe_b64encode(json.dumps(value, separators=(',',':')).encode()).decode().rstrip('=')
        value = encode({'alg':'HS256','typ':'JWT'}) + '.' + encode({'role':role,
          'iss':'supabase', 'iat':int(time.time()), 'exp':int(time.time()) + 172800})
        signature = base64.urlsafe_b64encode(hmac.new(self.projects[project]['secret'].encode(),
          value.encode(), hashlib.sha256).digest()).decode().rstrip('=')
        token = value + '.' + signature
        self.redactions.append(token)
        return token

    def request(self, project, path, body=None, *, token=None, key=None, method=None, headers=None):
        status,raw=self.exchange(project,path,None if body is None else json.dumps(body).encode(),
          token=token,key=key,method=method,headers=headers)
        return status,json.loads(raw) if raw else None

    def exchange(self, project, path, data=None, *, token=None, key=None, method=None, headers=None):
        config = self.projects[project]
        request = urllib.request.Request(config['url'] + path,
          data=data,
          headers={'apikey':key or config['anon'], 'Content-Type':'application/json',
            'Authorization':'Bearer ' + (token or config['anon']), **(headers or {})}, method=method)
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        try:
            response = opener.open(request, timeout=35)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            raw = response.read(4 * 1024 * 1024 + 1)
            self.schema.require(len(raw) <= 4 * 1024 * 1024, 'Runtime probe response exceeds bound')
            return response.status,raw

    def start(self):
        self.result['sourceSha'] = subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
        self.result['officeSourceSha'] = subprocess.check_output(['git','rev-parse','HEAD'],cwd=self.office_root,text=True).strip()
        self.result['sourceDirty'] = bool(subprocess.check_output(['git','status','--porcelain'],cwd=ROOT,text=True))
        self.result['officeSourceDirty'] = bool(subprocess.check_output(['git','status','--porcelain'],cwd=self.office_root,text=True))
        self.input_paths = [HERE / name for name in ['owned_platform.py','runtime_gateway.py','schema_snapshot.py',
          'run_schema_fixture.py','run_platform_probe.py','legal_http_scenario.py','store_http_scenario.py',
          'workforce_http_scenario.py','storage_runtime.py','storage_probe.py','realtime_runtime.py',
          'realtime_probe.py','realtime_probe.dart','kds_realtime_scenario.py','office_edge_runtime.ts','fixtures/attendance.jpg']]
        self.input_paths += [ROOT/'scripts/local_verification/fixture_postgres_policy.json']
        self.input_paths += [(ROOT if project=='pos' else self.office_root)/'supabase/migrations'/name
          for project in self.selected_projects for name in self.schema.CANDIDATE_MIGRATIONS[project]]
        # Include every tracked Edge module/lockfile, including transitive local
        # imports. Changes outside the executed app (e.g. UI-only edits) do not
        # silently turn this component proof into whole-app acceptance.
        for base in (ROOT,self.office_root):
            paths=subprocess.check_output(['git','ls-files','-z','supabase/functions'],cwd=base).split(b'\0')
            self.input_paths += [base/os.fsdecode(path) for path in paths if path]
        self.input_paths=list(dict.fromkeys(self.input_paths))
        self.result['toolHashes'] = self.input_hashes()
        for ref in (AUTH_IMAGE, REST_IMAGE):
            image = json.loads(self.command('image-' + ('auth' if ref == AUTH_IMAGE else 'rest'),
              [self.real_docker,'image','inspect',ref]).stdout)[0]
            self.check(ref in image['RepoDigests'] and image['Os'] == 'linux'
              and image['Architecture'] == 'amd64', 'pinned-' + ('auth' if ref == AUTH_IMAGE else 'rest') + '-image')
        anchor_image = next(p['derivedImageId'] for p in self.policy['additionalImages'] if '17-alpine' in p['requestedRef'])
        self.command('anchor', [self.real_docker,'run','-d','--name',self.anchor,
          '--label','pos.local.verification=' + self.run_id,'--tmpfs','/var/lib/postgresql/data:rw,size=1073741824',
          '--entrypoint','/bin/sh',anchor_image,'-c','exec sleep 129600'])
        self.command('network', ['docker','network','create',self.network])
        for project in self.selected_projects:
            self.start_project(project)
        private_json(self.output / 'runtime.private.json', {'runId':self.run_id, 'projects':self.projects})
        self.result['servicesPrepared'] = [service for p in self.selected_projects
          for service in ['native-'+p+'-db','real-'+p+'-auth',p+'-jwt-rest']] + ['loopback-project-api-routing']
        self.save()

    def start_project(self, project):
        prefix = self.network + '-' + project
        config = {'db':prefix + '-db','auth':prefix + '-auth','rest':prefix + '-rest',
          'secret':secrets.token_urlsafe(48), 'password':secrets.token_urlsafe(32)}
        self.projects[project] = config
        self.redactions.extend([config['secret'], config['password']])
        self.command(project + '-db', ['docker','run','-d','--name',config['db'],'--network',self.network,
          '--memory','2g','--cpus','2','--env','POSTGRES_PASSWORD=fixture-only','public.ecr.aws/supabase/postgres:17.6.1.104'])
        for attempt in range(60):
            ready = subprocess.run(['docker','exec',config['db'],'pg_isready','-h','127.0.0.1','-U','postgres'],
              env=self.env, capture_output=True).returncode == 0
            if ready:
                break
            if attempt%10==0 and not self.container_running(config['db'],project+'-db-'+str(attempt)):
                raise RuntimeError('Owned database exited before readiness')
            time.sleep(.5)
        else:
            raise RuntimeError('Owned database readiness timed out')
        self.sql(project, self.restores[project])
        references = self.schema.reference_sql(project, self.snapshot)
        if references:
            self.sql(project, references)
        self.check(True, project + '-native-schema-restored')
        self.result['migrations'][project] = []
        target = ROOT if project == 'pos' else self.office_root
        for name in self.schema.CANDIDATE_MIGRATIONS[project]:
            path = target / 'supabase/migrations' / name
            self.schema.require(path.is_file() and not path.is_symlink(), 'Missing forward migration')
            self.sql(project, path.read_text())
            self.result['migrations'][project].append({'file':name, 'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),
              'status':'APPLIED_TO_OWNED_FIXTURE_ONLY'})
        self.sql(project, 'ALTER ROLE supabase_auth_admin PASSWORD ' + literal(config['password']) + ';'
          'ALTER ROLE authenticator LOGIN NOINHERIT NOBYPASSRLS PASSWORD ' + literal(config['password']) + ';'
          'GRANT anon,authenticated,service_role TO authenticator;')
        self.result['cosmeticPermissionHintsDisabledFixtureOnly'] = True
        config['anon'], config['service'] = self.jwt(project,'anon'), self.jwt(project,'service_role')
        auth_env = self.output / (project + '-auth.env')
        values = {'GOTRUE_API_HOST':'0.0.0.0','GOTRUE_API_PORT':'9999','API_EXTERNAL_URL':'http://' + config['auth'] + ':9999',
          'GOTRUE_DB_DRIVER':'postgres','GOTRUE_DB_DATABASE_URL':'postgres://supabase_auth_admin:' + config['password'] + '@' + config['db'] + ':5432/postgres?options=-c%20supautils.hint_roles%3D',
          'GOTRUE_SITE_URL':'http://127.0.0.1','GOTRUE_JWT_SECRET':config['secret'],'GOTRUE_JWT_EXP':'3600',
          'GOTRUE_JWT_AUD':'authenticated','GOTRUE_JWT_ADMIN_ROLES':'service_role','GOTRUE_JWT_DEFAULT_GROUP_NAME':'authenticated',
          'GOTRUE_EXTERNAL_EMAIL_ENABLED':'true','GOTRUE_MAILER_AUTOCONFIRM':'true','GOTRUE_DISABLE_SIGNUP':'false',
          'GOTRUE_DB_MAX_POOL_SIZE':'4','GOTRUE_LOG_LEVEL':'warn'}
        auth_env.write_text('\n'.join(k + '=' + v for k,v in values.items()) + '\n')
        auth_env.chmod(0o600)
        self.command(project + '-auth', ['docker','run','-d','--name',config['auth'],'--network',self.network,
          '--memory','256m','--cpus','1','--env-file',str(auth_env),'--entrypoint','auth',AUTH_IMAGE,'serve'])
        schemas = 'public' if project == 'pos' else 'public,core,hr,ops,accounting,finance,documents,dashboard,system,inventory'
        rest_env = self.output / (project + '-rest.env')
        rest_env.write_text('\n'.join([
          'PGRST_DB_URI=postgres://authenticator:' + config['password'] + '@' + config['db'] + ':5432/postgres?options=-c%20supautils.hint_roles%3D',
          'PGRST_DB_ANON_ROLE=anon','PGRST_DB_SCHEMAS=' + schemas, 'PGRST_DB_EXTRA_SEARCH_PATH=public,extensions',
          'PGRST_JWT_SECRET=' + config['secret'], 'PGRST_DB_MAX_ROWS=100','PGRST_DB_POOL=8',
          'PGRST_SERVER_HOST=0.0.0.0','PGRST_SERVER_PORT=3000','PGRST_ADMIN_SERVER_PORT=3001','PGRST_LOG_LEVEL=warn']) + '\n')
        rest_env.chmod(0o600)
        self.command(project + '-rest', ['docker','run','-d','--name',config['rest'],'--network',self.network,
          '--memory','256m','--cpus','1','--env-file',str(rest_env),REST_IMAGE])
        rest_address = self.address(config['rest'])
        gateway = self.gateway_module.RuntimeGateway(project=project,run_id=self.run_id,
          auth='http://' + self.address(config['auth']) + ':9999',
          rest='http://' + rest_address + ':3000',anon=config['anon'],service=config['service'])
        self.gateways[project] = gateway
        thread = threading.Thread(target=gateway.serve_forever,daemon=True)
        thread.start()
        self.threads.append(thread)
        config['url'] = gateway.origin
        for _ in range(60):
            try:
                auth_ok = self.request(project,'/auth/v1/health')[0] == 200
                opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
                with opener.open('http://' + rest_address + ':3001/ready',timeout=1) as response:
                    rest_ok = response.status == 200
                if auth_ok and rest_ok:
                    break
            except OSError:
                pass
            time.sleep(.5)
        else:
            raise RuntimeError('Owned Auth/REST readiness timed out')
        self.check(True, project + '-real-auth-and-jwt-rest-ready')

    def close(self):
        failures=[]
        for process in self.processes:
            try:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=5)
            except (OSError,subprocess.TimeoutExpired) as error:
                failures.append(type(error).__name__)
        self.result['gatewayMetrics'] = {project:g.snapshot() for project,g in self.gateways.items()}
        for gateway in self.gateways.values():
            try:
                gateway.shutdown()
                gateway.server_close()
            except OSError as error:
                failures.append(type(error).__name__)
        for thread in self.threads:
            thread.join(timeout=2)
            if thread.is_alive():
                failures.append('GatewayThreadNotStopped')
        try:
            for project,config in self.projects.items():
                for kind in ('auth','rest','db','storage','realtime'):
                    if kind not in config:continue
                    self.command('diagnostic-' + project + '-' + kind, ['docker','logs','--tail','100',config[kind]],check=False)
        except (OSError,subprocess.TimeoutExpired) as error:
            failures.append(type(error).__name__)
        finally:
            try:
                self.result['cleanupVerified'] = self.runner.cleanup_owned(self.run_id,self.env) and not failures
            except (OSError,subprocess.TimeoutExpired) as error:
                failures.append(type(error).__name__)
                self.result['cleanupVerified']=False
            self.result['cleanupFailures']=failures
            self.result['gatewayMetricsFinal']={project:g.snapshot() for project,g in self.gateways.items()}
            if any(g.snapshot()['active'] for g in self.gateways.values()):
                self.result['cleanupVerified']=False
                self.result['cleanupFailures'].append('GatewayRequestStillActive')
            self.result['elapsedSeconds'] = time.monotonic() - self.started
            self.result['finishedAt'] = datetime.now(timezone.utc).isoformat()
            if not self.result['cleanupVerified']:
                self.result['status'] = 'FAIL'
            self.save()

    def input_hashes(self):
        return {str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in self.input_paths}

    def validate_inputs(self):
        self.check(self.result['toolHashes']==self.input_hashes(),
          'runtime-tool-inputs-unchanged')
        self.check(self.result['officeSourceSha']==subprocess.check_output(['git','rev-parse','HEAD'],cwd=self.office_root,text=True).strip()
          and not subprocess.check_output(['git','status','--porcelain'],cwd=self.office_root,text=True),
          'actual-office-source-sha-and-clean-tree-unchanged')

    def start_office_edge(self, deno, deno_cache):
        return self.start_edge('office','pos-bridge',deno,deno_cache)

    def start_edge(self, project, function_name, deno, deno_cache):
        self.schema.require((project,function_name) in [('office','pos-bridge'),('pos','store-account-onboarding'),
          ('pos','complete-initial-password-change')],
          'Only inspected local Edge entrypoints are supported')
        deno, deno_cache = Path(deno), Path(deno_cache)
        self.schema.require(deno.is_absolute() and os.access(deno,os.X_OK) and deno_cache.is_absolute(),
          'Explicit existing Deno executable/cache are required')
        target_root = self.office_root if project=='office' else ROOT
        source = target_root / 'supabase/functions' / function_name / 'index.ts'
        source_lock = source.parent/'deno.lock'
        if not source_lock.is_file():source_lock = self.office_root / 'scripts/deno.lock'
        lock = json.loads(source_lock.read_text())
        lock.pop('workspace', None)  # URL-only runtime has no tools/packageJson workspace.
        edge_key=project+'-'+function_name
        target_lock = self.output / (edge_key + '-edge-runtime.lock')
        private_json(target_lock, lock)
        self.result.setdefault('edgeLockDerivations',{})[edge_key] = {
          'sourceSha256':hashlib.sha256(source_lock.read_bytes()).hexdigest(),
          'derivedSha256':hashlib.sha256(target_lock.read_bytes()).hexdigest(),
          'onlyWorkspaceBookkeepingRemoved':True, 'remoteIntegrityEntries':len(lock.get('remote',{}))}
        ready = self.output / (edge_key + '-edge-ready.json')
        env = {'PATH':os.environ.get('PATH',''), 'DENO_DIR':str(deno_cache),
          'DENO_TLS_CA_STORE':'system','DENO_NO_UPDATE_CHECK':'1','DENO_NO_PACKAGE_JSON':'1',
          'POS_FIXTURE_EDGE_READY':str(ready), 'POS_FIXTURE_RUN_ID':self.run_id,
          'POS_FIXTURE_EDGE_FUNCTION':function_name, 'POS_FIXTURE_EDGE_SOURCE':source.as_uri(),
          'SUPABASE_URL':self.projects[project]['url'],
          'SUPABASE_SERVICE_ROLE_KEY':self.projects[project]['service'],
          'SUPABASE_ANON_KEY':self.projects[project]['anon'],
          'POS_SUPABASE_URL':self.projects['pos']['url'], 'POS_SECRET_KEY':self.projects['pos']['service']}
        if not hasattr(self,'dispatch_token'):
            self.dispatch_token=secrets.token_urlsafe(48)
            self.redactions.append(self.dispatch_token)
        env['PROCUREMENT_ONBOARDING_DISPATCH_TOKEN']=self.dispatch_token
        import_args=[]
        if project=='pos':
            env['STORE_ONBOARDING_INITIAL_PASSWORD']=self.projects['pos']['password']
            env['ALLOWED_ORIGINS']=self.projects['pos']['url']
            config_path=source.parent/'deno.json'
            if config_path.is_file():
                import_map=self.output/(edge_key+'-import-map.json')
                private_json(import_map,{'imports':json.loads(config_path.read_text())['imports']})
                import_args=['--import-map='+str(import_map)]
        log = self.output / ('actual-' + edge_key + '-edge.log')
        with log.open('w') as output:
            log.chmod(0o600)
            process = subprocess.Popen([str(deno),'run','--no-config','--no-npm','--cached-only','--no-check','--frozen',
              '--lock=' + str(target_lock),'--allow-net=127.0.0.1','--allow-env',
              '--allow-read=' + str(target_root) + ',' + str(HERE), '--allow-write=' + str(ready),
              *import_args,'--preload='+str(HERE / 'office_edge_runtime.ts'),str(source)],
              cwd=ROOT,env=env,stdout=output,stderr=subprocess.STDOUT,start_new_session=True)
        self.processes.append(process)
        for _ in range(100):
            if process.poll() is not None:
                raise RuntimeError('Actual Office Edge startup failed; private diagnostics retained')
            if ready.exists():
                record = json.loads(ready.read_text())
                self.schema.require(record.get('runId')==self.run_id and record.get('pid')==process.pid
                  and type(record.get('port')) is int and 0 < record['port'] < 65536,'Owned Edge readiness identity mismatch')
                ready.chmod(0o600)
                origin='http://127.0.0.1:' + str(record['port'])
                if project=='office':
                    self.gateways[project].edge=origin
                else:
                    self.gateways[project].additional_edges['/functions/v1/'+function_name]=origin
                self.result['servicesPrepared'].append('actual-' + project + '-' + function_name + '-edge')
                self.result.setdefault('edgeSourceSha256ByFunction',{})[edge_key] = hashlib.sha256(source.read_bytes()).hexdigest()
                self.check(True,'actual-' + project + '-edge-bound-to-owned-loopback-port')
                return
            time.sleep(.1)
        raise RuntimeError('Owned Edge readiness deadline reached')
