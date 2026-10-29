#!/usr/bin/env python3
"""Use the pinned, freshly verified tool image without host SDK installation."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time

from bridge import ROOT, CloudError, require, session, write_new

sys.path.insert(0, str(ROOT / 'scripts'))
import pos_local_release_gate as gate

PUBLIC_BUILD_ENV = ('SUPABASE_URL', 'SUPABASE_ANON_KEY', 'FIREBASE_API_KEY',
                    'FIREBASE_APP_ID', 'FIREBASE_MESSAGING_SENDER_ID',
                    'FIREBASE_PROJECT_ID', 'FIREBASE_WEB_VAPID_KEY')


def checked(arguments):
    return subprocess.check_output(arguments, text=True, stderr=subprocess.STDOUT).strip()


def initialize(directory, evidence):
    directory, manifest = session(directory)
    receipt = gate.verify(Path(evidence), ROOT, kind='exact-main')
    image = receipt['environment']['image']['Id']
    name = 'pos-cloud-tools-' + manifest['runId']
    command = ['docker', 'run', '-d', '--name', name, '--user', 'root', '--group-add', '0',
               '--label', 'pos.local.verification=' + manifest['runId'],
               '--mount', 'type=bind,src=' + str(ROOT) + ',dst=' + str(ROOT),
               '--mount', 'type=bind,src=' + str(directory) + ',dst=' + str(directory),
               '--mount', 'type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock',
               '--workdir', str(ROOT), '--env', 'POS_LOCAL_RUN_ID=' + manifest['runId'],
               '--env', 'POS_LOCAL_TOOL_CONTAINER=' + name,
               '--env', 'POS_VERIFICATION_ARTIFACTS=' + str(directory / 'fixtures'),
               '--env', 'PATH=' + str(ROOT / 'scripts/local_verification') +
               ':/opt/flutter/bin:/usr/local/bin:/usr/lib/postgresql/16/bin:/usr/sbin:/usr/bin:/sbin:/bin']
    # Reuse only mappings validated by this invocation's exact-main receipt.
    # The post-gate SQL checks must use the same pinned one-layer fixtures,
    # not request mutable upstream tags on a VFS engine.
    projection = receipt['environment'].get('fixtureProjection')
    if projection:
        projections = [projection, *receipt['environment'].get('additionalFixtureProjections', [])]
        command += ['--env', 'POS_FIXTURE_IMAGE_MAP=' + json.dumps(
            {p['requestedRef']: p['derivedImageId'] for p in projections}, separators=(',', ':'))]
    for variable in gate.proxy_environment(os.environ):
        command += ['--env', variable]
    command += gate.proxy_host_arguments(os.environ)
    trust = gate.proxy_trust(os.environ.get('CODEX_PROXY_CERT'), '/etc/ssl/certs/ca-certificates.crt')
    setup = ''
    if trust:
        command += ['--mount', 'type=bind,src=' + trust['certificate'] +
                    ',dst=/usr/local/share/ca-certificates/pos-platform-proxy.crt,readonly']
        setup = 'update-ca-certificates >/dev/null; '
        command += ['--env', 'DENO_TLS_CA_STORE=system']
    command += ['--entrypoint', '/bin/bash', image, '-c',
                'set -e; ' + setup + 'touch /tmp/pos-cloud-tools-ready; exec sleep infinity']
    identifier = checked(command)
    write_new(directory / 'sdk.json', {'container': name, 'id': identifier,
              'image': image, 'runId': manifest['runId'], 'sourceSha': manifest['sourceSha']})
    for _ in range(100):
        if subprocess.run(['docker', 'exec', name, 'test', '-f', '/tmp/pos-cloud-tools-ready'],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
            return
        time.sleep(.1)
    raise CloudError('Pinned tool container did not become ready')


def tool(directory, name, arguments):
    directory, manifest = session(directory)
    require(name in {'flutter', 'dart', 'checks'}, 'Unsupported pinned tool')
    data = json.loads((directory / 'sdk.json').read_text())
    require(data['sourceSha'] == manifest['sourceSha'] and data['runId'] == manifest['runId'],
            'Tool container belongs to another release')
    actual = json.loads(checked(['docker', 'inspect', data['container']]))[0]
    require(actual.get('Id') == data['id'] and actual.get('Image') == data['image']
            and (actual.get('Config', {}).get('Labels') or {}).get('pos.local.verification') == manifest['runId'],
            'Wrong or unowned pinned tool container')
    command = ['docker', 'exec', '--user', str(os.getuid()) + ':1000', '--workdir', str(ROOT)]
    if name == 'checks':
        command += ['--env', 'POS_CLOUD_TEST_TARGETS=' + os.environ.get('TEST_TARGETS',
                    'test/pilot_feedback_closure_contract_test.dart')]
        body = 'source scripts/deploy_pos_production.sh; DRY_RUN=0; SKIP_CHECKS=0; '
        body += 'DB_ONLY=' + ('1' if manifest['phase'] == 'db-only' else '0') + '; '
        body += 'TEST_TARGETS="$POS_CLOUD_TEST_TARGETS"; run_checks'
        command += [data['container'], 'bash', '-e', '-c', body]
    else:
        # The compiler gets frontend configuration only, never CLI tokens or
        # fixed-account passwords from the host/Vercel environment.
        for variable in PUBLIC_BUILD_ENV:
            if variable in os.environ:
                command += ['--env', variable]
        command += [data['container'], name, *arguments]
    return subprocess.run(command).returncode


def close(directory):
    directory, manifest = session(directory)
    path = directory / 'sdk.json'
    if not path.exists():
        return
    data = json.loads(path.read_text())
    probe = subprocess.run(['docker', 'inspect', data['container']], capture_output=True, text=True)
    if probe.returncode == 0:
        actual = json.loads(probe.stdout)[0]
        require(actual['Id'] == data['id'] and
                actual['Config']['Labels'].get('pos.local.verification') == manifest['runId'],
                'Refusing cleanup of another executor\'s container')
        subprocess.run(['docker', 'rm', '-f', data['container']], check=True, stdout=subprocess.DEVNULL)
    gate.cleanup_fixtures(manifest['runId'])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['init', 'close', 'flutter', 'dart', 'checks'])
    parser.add_argument('--directory', default=os.environ.get('POS_CLOUD_BRIDGE_DIR'))
    parser.add_argument('--evidence')
    args, remaining = parser.parse_known_args()
    require(args.directory, 'Missing live cloud SDK execution directory')
    if args.action == 'init':
        initialize(args.directory, args.evidence)
    elif args.action == 'close':
        close(args.directory)
    else:
        return tool(args.directory, args.action, remaining)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (CloudError, gate.InvalidEvidence, OSError, ValueError, KeyError, subprocess.CalledProcessError):
        print('POS_CLOUD_SDK_BLOCKED: pinned tool execution failed; inspect sanitized release logs', file=sys.stderr)
        sys.exit(1)
