#!/usr/bin/env python3
"""Run the reviewed recipe locally; never accept a caller-supplied PASS receipt.

Production calls `run --kind exact-main`. `verify` detects stale/incomplete or
damaged evidence for review; it does not authorize a deployment or remote merge.
"""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import signal
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import uuid
from urllib.parse import urlsplit

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent / 'local_verification'))
from evidence import InvalidEvidence, evidence_file, parse_counts, require, sha256
from fixture_image import DiskMonitor, policy as fixture_policy, validate_image, verify_proof

ROOT = Path(__file__).resolve().parents[1]
CONTRACT = ['scripts/local_verification/recipe.json',
            'scripts/local_verification/Dockerfile',
            'scripts/local_verification/evidence.py',
            'scripts/local_verification/docker', 'scripts/local_verification/port_proxy.py',
            'scripts/pos_local_release_gate.py',
            'scripts/local_verification/fixture_image.py',
            'scripts/local_verification/fixture_postgres_policy.json']


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def checked(argv, cwd=ROOT):
    return subprocess.check_output(argv, cwd=cwd, text=True, stderr=subprocess.STDOUT).strip()


def source(root):
    require(not checked(['git', 'status', '--porcelain', '--untracked-files=all'], root),
            'A clean committed source checkout is required')
    head = checked(['git', 'rev-parse', 'HEAD'], root)
    names = filter(None, checked(['git', 'ls-files', '-z'], root).split('\0'))
    hashes = {}
    for name in names:
        path = root / name
        hashes[name] = (hashlib.sha256(os.readlink(path).encode()).hexdigest()
                        if path.is_symlink() else sha256(path))
    digest = hashlib.sha256(json.dumps(hashes, sort_keys=True).encode()).hexdigest()
    return {'sha': head, 'treeSha': checked(['git', 'rev-parse', 'HEAD^{tree}'], root),
            'fingerprint': digest, 'inputHashes': hashes}


def recipe(root):
    return json.loads((root / CONTRACT[0]).read_text())


def contract_hash(root):
    return hashlib.sha256(json.dumps({p: sha256(root / p) for p in CONTRACT},
                                     sort_keys=True).encode()).hexdigest()


def proxy_trust(proxy_cert, host_bundle):
    """Use only a public platform CA already present in the host trust bundle."""
    if not proxy_cert:
        return None
    certificate_path, bundle_path = Path(proxy_cert), Path(host_bundle)
    require(certificate_path.is_file() and bundle_path.is_file(), 'Proxy CA or host trust bundle missing')
    certificate = certificate_path.read_text()
    require('PRIVATE KEY' not in certificate, 'Proxy CA must not contain a private key')
    pattern = r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----'
    parts = re.findall(pattern, certificate, re.S)
    require(len(parts) == 1 and not re.sub(pattern, '', certificate, flags=re.S).strip(),
            'Expected exactly one public proxy CA certificate')
    root_der = ssl.PEM_cert_to_DER_cert(parts[0])
    bundle = bundle_path.read_text()
    require('PRIVATE KEY' not in bundle, 'Host trust bundle must not contain a private key')
    host_roots = re.findall(pattern, bundle, re.S)
    require(any(ssl.PEM_cert_to_DER_cert(item) == root_der for item in host_roots),
            'Proxy CA is not in the existing host trust bundle')
    return {'bundle': str(bundle_path.resolve()), 'certificate': str(certificate_path.resolve()),
            'proxyCaSha256': hashlib.sha256(root_der).hexdigest(),
            'hostBundleSha256': sha256(bundle_path)}


def proxy_environment(environment):
    """Forward only the host's credential-free managed network route."""
    names = []
    for name in ('HTTP_PROXY', 'HTTPS_PROXY', 'http_proxy', 'https_proxy',
                 'NO_PROXY', 'no_proxy'):
        value = environment.get(name)
        if not value:
            continue
        require(not any(ord(c) < 32 for c in value), 'Invalid proxy environment')
        if name.lower() != 'no_proxy':
            parsed = urlsplit(value)
            require(parsed.scheme in {'http', 'https'} and parsed.hostname
                    and parsed.username is None and parsed.password is None
                    and not parsed.query and not parsed.fragment,
                    'Only credential-free HTTP proxy settings may enter verification')
        names.append(name)
    return names


def proxy_host_arguments(environment):
    """Project the existing host DNS answer for its managed proxy into Docker.

    Nested bridge DNS can answer from a different network. This preserves the
    configured proxy URL/port and the host's current route; it does not resolve
    target services directly or add another proxy/fallback.
    """
    names = proxy_environment(environment)
    hosts = sorted({urlsplit(environment[name]).hostname for name in names
                    if name.lower() != 'no_proxy'})
    arguments = []
    for host in hosts:
        answers = sorted({item[4][0] for item in socket.getaddrinfo(
            host, None, socket.AF_INET, socket.SOCK_STREAM)})
        require(answers, 'Managed proxy has no host DNS answer')
        for address in answers:
            arguments += ['--add-host', host + ':' + address]
    return arguments


def exact_main(root):
    remote = checked(['git', 'remote', 'get-url', 'origin'], root)
    require(remote in {'https://github.com/ahc0403-commits/globospossystem.git',
                       'git@github.com:ahc0403-commits/globospossystem.git'},
            'Unexpected source repository')
    checked(['git', 'fetch', '--quiet', 'origin', '+refs/heads/main:refs/remotes/origin/main'], root)
    require(checked(['git', 'rev-parse', 'HEAD'], root) ==
            checked(['git', 'rev-parse', 'origin/main'], root), 'Fresh exact-main SHA required')


def write_receipt(directory, receipt):
    temp = directory / 'receipt.json.tmp'
    temp.write_text(json.dumps(receipt, indent=2, sort_keys=True) + '\n')
    temp.replace(directory / 'receipt.json')


def recorded(directory, name, argv, timeout, cwd=ROOT, env=None):
    path = directory / (name + '.log')
    start, monotonic = now(), time.monotonic()
    with path.open('wb') as log:
        process = subprocess.Popen(argv, cwd=cwd, stdout=log, stderr=subprocess.STDOUT, env=env,
                                   start_new_session=True)
        try:
            code = process.wait(timeout=timeout)
        except (subprocess.TimeoutExpired, KeyboardInterrupt, InterruptedError) as error:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            code = 124 if isinstance(error, subprocess.TimeoutExpired) else 130
    return {'id': name, 'command': shlex.join(argv), 'startedAt': start, 'finishedAt': now(),
            'durationMs': round((time.monotonic() - monotonic) * 1000), 'exitCode': code,
            'log': path.name, 'logSha256': sha256(path)}


def tool_probe():
    # No environment dump: the container receives only fixed fixture settings.
    return ['python3', '-c', '''import json,platform,subprocess
def v(a): return subprocess.check_output(a,text=True).strip()
f=json.loads(v(['flutter','--version','--machine']))
os=dict(x.strip().split('=',1) for x in open('/etc/os-release') if '=' in x)
print(json.dumps({'osId':os['ID'].strip('"'),'osVersion':os['VERSION_ID'].strip('"'),
 'arch':platform.machine(),'flutter':f['frameworkVersion'],'frameworkRevision':f['frameworkRevision'],
 'dart':f['dartSdkVersion'],'node':v(['node','--version']),
 'deno':v(['deno','--version']).splitlines()[0].split()[1],
 'chrome':v(['/opt/chrome-linux64/chrome','--version']).split()[-1],
 'postgres':v(['psql','--version']),'python':platform.python_version(),
 'git':v(['git','--version']),'docker':v(['/usr/bin/docker','--version']),
 'packages':v(['dpkg-query','-W','-f=${binary:Package}=${Version}\\n'])}))''']


def validate_tools(environment, expected):
    require(environment['osId'] == 'ubuntu' and environment['osVersion'] == '24.04'
            and environment['arch'] == 'x86_64', 'Required local Ubuntu 24.04 x86_64 missing')
    for key, value in expected['tools'].items():
        require(environment.get(key) == value, 'Wrong local tool version: ' + key)


def verify(directory, root=ROOT, kind=None, run_id=None):
    value = json.loads(evidence_file(directory, 'receipt.json').read_text())
    expected = recipe(root)
    require(value.get('schemaVersion') == 1 and value.get('type') == 'pos-local-verification', 'Wrong evidence type')
    require(value.get('completed') is True and value.get('status') == 'PASS', 'Incomplete/failed evidence')
    require(value.get('kind') == kind if kind else value.get('kind') in {'candidate', 'exact-main'}, 'Wrong evidence kind')
    require(run_id is None or value.get('runId') == run_id, 'Receipt was not produced by this invocation')
    require(value.get('sourceBefore') == source(root) == value.get('sourceAfter'), 'Source changed or stale SHA')
    require(value.get('contractSha256') == contract_hash(root), 'Recipe/runner changed')
    end = dt.datetime.fromisoformat(value['finishedAt'])
    start = dt.datetime.fromisoformat(value['startedAt'])
    age = dt.datetime.now(dt.timezone.utc) - end
    require(start.tzinfo and end.tzinfo and dt.timedelta() <= age <= dt.timedelta(hours=6)
            and end >= start, 'Stale/invalid evidence timestamps')
    auxiliaries = [value['imageBuild'], value['toolProbe']]
    projection = value['environment'].get('fixtureProjection')
    if projection:
        verify_proof(projection, value['runId'], value['sourceBefore']['sha'])
        auxiliaries.append(value['fixturePreparation'])
    for auxiliary in auxiliaries:
        require(auxiliary['exitCode'] == 0, 'Environment bootstrap/probe failed')
        log = evidence_file(directory, auxiliary['log'])
        require(sha256(log) == auxiliary['logSha256'], 'Environment log changed')
    probe = json.loads(evidence_file(directory, value['toolProbe']['log']).read_text().splitlines()[-1])
    require(probe == value['environment']['linux'], 'Tool evidence mismatch')
    validate_tools(probe, expected)
    require(value['environment']['image']['Os'] == 'linux' and
            value['environment']['image']['Architecture'] == 'amd64', 'Wrong local image platform')
    require(len(value['steps']) == len(expected['steps']), 'Missing/extra recipe steps')
    for step, fixed in zip(value['steps'], expected['steps']):
        require(step['id'] == fixed['id'] and step['argv'] == fixed['argv'], 'Changed command/order')
        require(step['command'].endswith(shlex.join(fixed['argv'])) and
                step['commandSha256'] == hashlib.sha256(json.dumps(fixed['argv']).encode()).hexdigest(),
                'Executed command digest mismatch')
        require(step['sourceSha'] == value['sourceBefore']['sha'] and step['exitCode'] == 0, 'Failed/stale step')
        begin, finish = dt.datetime.fromisoformat(step['startedAt']), dt.datetime.fromisoformat(step['finishedAt'])
        require(start <= begin <= finish <= end and
                abs((finish - begin).total_seconds()*1000 - step['durationMs']) < 2000 and
                step['durationMs'] <= (fixed['timeoutSeconds'] + 30)*1000, 'Invalid step timestamps')
        log = evidence_file(directory, step['log'])
        require(sha256(log) == step['logSha256'], 'Log missing/tampered')
        require(parse_counts(fixed, log.read_text(errors='replace'), root) == step['counts'], 'False assertion counts')
    fixtures = [json.loads(line) for line in evidence_file(directory, 'nested/fixture-images.jsonl').read_text().splitlines()]
    require(fixtures and all(x['runId'] == value['runId'] for x in fixtures), 'Foreign/missing fixture ownership')
    require({x['imageId'] for x in fixtures} == {x['Id'] for x in value['environment']['fixtureImages']},
            'Missing DB/fixture image identities')
    require(all(x['Os'] == 'linux' for x in value['environment']['fixtureImages']), 'Wrong fixture OS')
    fixed = fixture_policy()
    for image in value['environment']['fixtureImages']:
        if image['Id'] == fixed['derivedImageId']:
            require(projection is not None, 'Derived fixture provenance missing')
            require(image.get('rootfsLayers') == ['sha256:' + fixed['rootfsArchiveSha256']] and
                    image.get('runtimeConfigSha256') == fixed['runtimeConfigSha256'],
                    'Derived fixture filesystem/config evidence differs')
    for fixture in fixtures:
        if fixture.get('requestedImageRef'):
            require(projection is not None and fixture['requestedImageRef'] == fixed['requestedRef'] and
                    fixture['imageId'] == fixed['derivedImageId'] and
                    fixture.get('representation') == fixed['representation'], 'Fixture mapping differs')
    usage = value['filesystemUsage']
    disk_log = evidence_file(directory, usage['log'])
    require(sha256(disk_log) == usage['logSha256'], 'Disk sampling evidence changed')
    disk = json.loads(disk_log.read_text())
    require(disk['samplingIntervalSeconds'] == 1 and len(disk['samples']) >= 2,
            'Disk sampling evidence missing')
    require(disk['minimumAvailableBytes'] == min(x['availableBytes'] for x in disk['samples']) and
            disk['maximumUsedBytes'] == max(x['usedBytes'] for x in disk['samples']) and
            disk['minimumAvailableBytes'] >= 0, 'False disk peak summary')
    require(all(start <= dt.datetime.fromisoformat(x['at']) <= end for x in disk['samples']),
            'Disk samples outside invocation')
    require(value.get('artifacts'), 'Missing build artifacts')
    names = set()
    for artifact in value['artifacts']:
        path = evidence_file(directory, artifact['path'])
        require(path.stat().st_size == artifact['bytes'] > 0 and sha256(path) == artifact['sha256'], 'Artifact changed')
        names.add(artifact['path'])
    require({'artifacts/web/index.html', 'artifacts/web/main.dart.js',
             'artifacts/web/flutter_bootstrap.js', 'artifacts/web/photo_import_worker.js'} <= names,
            'Required web build outputs missing')
    return value


def cleanup_fixtures(run_id):
    # Only labels generated by this invocation; no prune or unrelated task stop.
    for kind, listing, remove in [('container', ['ps', '-aq'], ['rm', '-f']),
                                  ('network', ['network', 'ls', '-q'], ['network', 'rm'])]:
        result = subprocess.run(['docker'] + listing + ['--filter', 'label=pos.local.verification=' + run_id],
                                capture_output=True, text=True)
        if result.returncode == 0 and result.stdout.split():
            subprocess.run(['docker'] + remove + result.stdout.split(), capture_output=True)


def run(directory, kind, root=ROOT):
    before = source(root)
    if kind == 'exact-main':
        exact_main(root)
    expected = recipe(root)
    directory = directory.resolve()
    require(not directory.is_relative_to(root.resolve()), 'Evidence must be outside source checkout')
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    run_id = uuid.uuid4().hex
    value = {'schemaVersion': 1, 'type': 'pos-local-verification', 'kind': kind, 'runId': run_id,
             'startedAt': now(), 'timezone': 'UTC', 'sourceBefore': before,
             'contractSha256': contract_hash(root), 'completed': False, 'status': 'RUNNING',
             'steps': [], 'environment': {'host': {'os': platform.system(),
              'arch': platform.machine(), 'release': platform.release(), 'python': platform.python_version(),
              'docker': checked(['docker', '--version'])}},
             'scope': 'Web/server release. Native Windows package requires its unchanged native build path; Linux exclusions are not PASS.'}
    write_receipt(directory, value)
    name = 'pos-local-verify-' + run_id
    container_created = False
    disk_monitor = DiskMonitor(directory).start()
    def finish_disk():
        area = directory / 'nested'
        area.mkdir(exist_ok=True)
        path = area / 'filesystem-usage.json'
        path.write_text(json.dumps(disk_monitor.stop(), indent=2) + '\n')
        value['filesystemUsage'] = {'log': str(path.relative_to(directory)), 'logSha256': sha256(path)}
    try:
        endpoint = checked(['docker', 'context', 'inspect', '--format', '{{.Endpoints.docker.Host}}'])
        require(not os.environ.get('DOCKER_HOST') and endpoint.startswith('unix://'), 'Only an existing local Docker engine is allowed')
        engine = checked(['docker', 'info', '--format', '{{.Driver}} {{.OSType}} {{.Architecture}}']).split()
        value['environment']['engineStorageDriver'] = engine[0]
        projection = None
        if engine[0] == 'vfs' and engine[1:] in (['linux', 'x86_64'], ['linux', 'amd64']):
            path = directory / 'nested/fixture-projection.json'
            value['fixturePreparation'] = recorded(directory, 'fixture-preparation',
                [sys.executable, '-B', str(root / 'scripts/local_verification/fixture_image.py'),
                 '--output', str(path), '--run-id', run_id, '--source-sha', before['sha'],
                 '--docker-endpoint', endpoint], 1200)
            require(value['fixturePreparation']['exitCode'] == 0, 'Verified fixture preparation failed')
            projection = json.loads(path.read_text())
            verify_proof(projection, run_id, before['sha'])
            value['environment']['fixtureProjection'] = projection
        trust = proxy_trust(os.environ.get('CODEX_PROXY_CERT'), '/etc/ssl/certs/ca-certificates.crt')
        if trust:
            value['environment']['proxyTrust'] = {k: trust[k] for k in ('proxyCaSha256', 'hostBundleSha256')}
        proxy_names = proxy_environment(os.environ)
        value['environment']['managedProxyVariables'] = proxy_names
        proxy_hosts = proxy_host_arguments(os.environ)
        value['environment']['managedProxyHostArguments'] = proxy_hosts
        build = ['docker', 'build', '--platform', 'linux/amd64'] + proxy_hosts
        for variable in proxy_names:
            build += ['--build-arg', variable]
        if trust:
            build += ['--secret', 'id=host_ca_bundle,src=' + trust['bundle']]
        build += ['--iidfile', str(directory / 'image.id'), '-f', str(root / CONTRACT[1]),
                  str(root / 'scripts/local_verification')]
        # Buildx state must be writable without changing HOME, Docker contexts,
        # registry credentials, or system configuration in managed cloud hosts.
        buildx = directory / 'buildx-state'
        buildx.mkdir(mode=0o700)
        build_environment = dict(os.environ, BUILDX_CONFIG=str(buildx))
        value['imageBuild'] = recorded(directory, 'image-build', build, 2400,
                                       env=build_environment)
        require(value['imageBuild']['exitCode'] == 0, 'Local environment build failed')
        image_id = (directory / 'image.id').read_text().strip()
        image = json.loads(checked(['docker', 'image', 'inspect', image_id]))[0]
        value['environment']['image'] = {k: image[k] for k in ['Id', 'Os', 'Architecture']}
        with tempfile.TemporaryDirectory(prefix='pos-verify-source-') as temporary:
            snapshot = Path(temporary) / 'source'
            checked(['git', 'clone', '--quiet', '--no-hardlinks', '--no-checkout', str(root), str(snapshot)])
            checked(['git', 'checkout', '--quiet', '--detach', before['sha']], snapshot)
            require(source(snapshot) == before, 'Snapshot differs from committed source')
            uid = os.getuid()
            docker_run = ['docker', 'run', '-d', '--name', name, '--label', 'pos.local.verification=' + run_id, '--group-add', '0',
                     '--user', 'root', '--shm-size', '1g',
                     '-v', '/var/run/docker.sock:/var/run/docker.sock',
                     '-v', str(snapshot) + ':' + str(snapshot),
                     '-v', str(directory) + ':' + str(directory),
                    ]
            docker_run += proxy_hosts
            if projection:
                docker_run += ['--env', 'POS_POSTGRES_FIXTURE_IMAGE=' + projection['derivedImageId']]
            for variable in proxy_names:
                docker_run += ['--env', variable]
            if trust:
                docker_run += ['--mount', 'type=bind,src=' + trust['bundle'] + ',dst=/run/pos-host-ca.pem,readonly']
                docker_run += ['--mount', 'type=bind,src=' + trust['certificate'] +
                               ',dst=/usr/local/share/ca-certificates/pos-platform-proxy.crt,readonly']
                for variable in ('SSL_CERT_FILE', 'CURL_CA_BUNDLE', 'GIT_SSL_CAINFO',
                                 'REQUESTS_CA_BUNDLE', 'NODE_EXTRA_CA_CERTS'):
                    docker_run += ['--env', variable + '=/run/pos-host-ca.pem']
                docker_run += ['--env', 'DENO_TLS_CA_STORE=system']
            runtime_trust = ('update-ca-certificates >/dev/null; '
                             'openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt '
                             '/usr/local/share/ca-certificates/pos-platform-proxy.crt >/dev/null; ')
            checked(docker_run + [
                     '--env', 'POS_LOCAL_RUN_ID=' + run_id,
                     '--env', 'POS_LOCAL_TOOL_CONTAINER=' + name,
                     '--env', 'POS_VERIFICATION_ARTIFACTS=' + str(directory / 'nested'),
                     '--env', 'PATH=' + str(snapshot / 'scripts/local_verification') + ':' +
                       '/opt/flutter/bin:/usr/local/bin:/usr/lib/postgresql/16/bin:/usr/sbin:/usr/bin:/sbin:/bin',
                     '--workdir', str(snapshot), '--entrypoint', '/bin/bash', image_id, '-c',
                     'set -e; ' + (runtime_trust if trust else '') +
                     f'getent passwd {uid} >/dev/null || useradd --uid {uid} --gid 1000 --home-dir /home/ubuntu --no-create-home posverify; chown -R {uid}:1000 /home/ubuntu; exec sleep infinity'])
            container_created = True
            execute = ['docker', 'exec', '--user', str(uid) + ':1000', name]
            value['toolProbe'] = recorded(directory, 'tools', execute + tool_probe(), 120)
            require(value['toolProbe']['exitCode'] == 0, 'Local tool probe failed')
            value['environment']['linux'] = json.loads((directory / 'tools.log').read_text().splitlines()[-1])
            validate_tools(value['environment']['linux'], expected)
            for step in expected['steps']:
                print('POS_LOCAL_STEP=' + step['id'], flush=True)
                record = recorded(directory, step['id'], execute + ['timeout', '--kill-after=10s',
                                  str(step['timeoutSeconds'])] + step['argv'], step['timeoutSeconds'] + 30)
                record.update({'argv': step['argv'], 'sourceSha': before['sha'],
                               'commandSha256': hashlib.sha256(json.dumps(step['argv']).encode()).hexdigest()})
                value['steps'].append(record)
                write_receipt(directory, value)
                require(record['exitCode'] == 0, 'Failed local step: ' + step['id'])
                record['counts'] = parse_counts(step, (directory / record['log']).read_text(errors='replace'), snapshot)
                require(source(snapshot) == before == source(root), 'Source changed during verification')
                write_receipt(directory, value)
            fixtures = [json.loads(line) for line in
                        (directory / 'nested/fixture-images.jsonl').read_text().splitlines()]
            require(fixtures and all(x['runId'] == run_id for x in fixtures), 'Missing/foreign fixture image evidence')
            image_ids = sorted({x['imageId'] for x in fixtures})
            images = json.loads(checked(['docker', 'image', 'inspect'] + image_ids))
            value['environment']['fixtureImages'] = [
                {k: x[k] for k in ['Id', 'Os', 'Architecture', 'RepoDigests']} for x in images]
            for info, image_value in zip(value['environment']['fixtureImages'], images):
                if projection and info['Id'] == projection['derivedImageId']:
                    validate_image(image_value)
                    info.update(rootfsLayers=image_value['RootFS']['Layers'],
                                runtimeConfigSha256=projection['runtimeConfigSha256'])
            shutil.copytree(snapshot / 'build/web', directory / 'artifacts/web')
            finish_disk()
            value['artifacts'] = [{'path': str(f.relative_to(directory)), 'sha256': sha256(f), 'bytes': f.stat().st_size}
                                  for area in ['artifacts', 'nested']
                                  for f in sorted((directory / area).rglob('*')) if f.is_file()]
            value['sourceAfter'] = source(root)
            require(value['sourceAfter'] == before == source(snapshot), 'Source changed after verification')
            if kind == 'exact-main':
                exact_main(root)
            value.update({'finishedAt': now(), 'completed': True, 'status': 'PASS'})
            write_receipt(directory, value)
            verify(directory, root, kind, run_id)
        print('POS_LOCAL_VERIFICATION_PASS ' + before['sha'] + ' ' + str(directory / 'receipt.json'))
        return 0
    except (InvalidEvidence, subprocess.CalledProcessError, OSError, ValueError, KeyError, KeyboardInterrupt) as error:
        finish_disk()
        value.update({'finishedAt': now(), 'completed': False, 'status': 'FAIL', 'failure': str(error)})
        write_receipt(directory, value)
        print('POS_LOCAL_VERIFICATION_BLOCKED: ' + str(error), file=sys.stderr)
        return 1
    finally:
        disk_monitor.stop()
        if container_created:
            subprocess.run(['docker', 'rm', '-f', name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cleanup_fixtures(run_id)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='action', required=True)
    execute = sub.add_parser('run')
    execute.add_argument('--kind', required=True, choices=['candidate', 'exact-main'])
    execute.add_argument('--output', type=Path, required=True)
    inspect = sub.add_parser('verify')
    inspect.add_argument('--evidence', type=Path, required=True)
    inspect.add_argument('--kind', choices=['candidate', 'exact-main'])
    args = parser.parse_args()
    try:
        if args.action == 'run':
            return run(args.output, args.kind)
        value = verify(args.evidence, ROOT, args.kind)
        print('POS_LOCAL_EVIDENCE_INTEGRITY_PASS ' + value['sourceBefore']['sha'])
        return 0
    except (InvalidEvidence, subprocess.CalledProcessError, OSError, ValueError, KeyError) as error:
        print('POS_LOCAL_VERIFICATION_BLOCKED: ' + str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    def interrupted(signum, frame):
        raise KeyboardInterrupt('Local verification interrupted')
    signal.signal(signal.SIGTERM, interrupted)
    sys.exit(main())
