#!/usr/bin/env python3
"""Official deployer's authenticated Vercel build executor.

The provider consumes its existing build environment; this adapter never lists,
decrypts, copies or changes Vercel environment variables. A configuration/build
attestation from the exact Git source is required before success is reported.
"""
import argparse
import hashlib
import json
from pathlib import Path
import time
import urllib.request

from bridge import ROOT, CloudError, canonical, request, require, session, write_new

TEAM = 'team_4AfACJKDlP09zRqoJKce3Tib'
PROJECT = 'prj_glOhZuHqHUHyAsGaSx5BVip3MIJJ'
NAME = 'globospossystem'
HOST = 'globospossystem.vercel.app'
LIVE = 'https://' + HOST


def deployment_arguments(sha):
    return {'teamId': TEAM, 'requestBody': {
        'name': NAME, 'project': PROJECT, 'target': 'production',
        'gitSource': {'type': 'github', 'org': 'ahc0403-commits',
                      'repo': NAME, 'ref': sha, 'sha': sha},
        'withLatestCommit': False,
        'meta': {'githubCommitSha': sha, 'githubCommitRef': 'main',
                 'githubCommitOrg': 'ahc0403-commits', 'githubCommitRepo': NAME},
    }}


def authorize_mutation(directory, manifest, arguments):
    require(manifest['phase'] == 'web-only', 'Vercel write requires web-only phase')
    require(arguments == deployment_arguments(manifest['sourceSha']), 'Unbound Vercel target or Git source')
    prepared = json.loads((Path(directory) / 'vercel-prepared.json').read_text())
    require(prepared['arguments'] == arguments and prepared['sourceSha'] == manifest['sourceSha'],
            'Vercel payload differs from prepared release')
    require(not (Path(directory) / 'vercel-created.json').exists(), 'Vercel deployment already created')


def verify_deployment(value, sha, identifier=None):
    require(value.get('readyState') == 'READY' and value.get('target') == 'production',
            'Vercel deployment is not READY production')
    require(value.get('projectId') == PROJECT or (value.get('project') or {}).get('id') == PROJECT,
            'Vercel returned another project')
    provider_sha = (value.get('gitSource') or {}).get('sha')
    # `source` describes the deployment initiator. The API can create an
    # exact-Git deployment while mapped inspection omits gitSource. Its prepared
    # request and actual build Git identity/compiled bytes are checked as well.
    require((value.get('meta') or {}).get('githubCommitSha') == sha
            and (provider_sha == sha or (provider_sha is None and value.get('source') in {'git', 'api'})),
            'Provider Git source is not release SHA')
    if identifier:
        require(value.get('id') == identifier, 'Production alias points to another deployment')


def verify_build(value, sha, lock_hash):
    require(value.get('schemaVersion') == 1 and value.get('sourceSha') == sha,
            'Live build source mismatch')
    require(value.get('publicConfigStatus') == 'PASS'
            and value.get('flutterVersion') == '3.41.6'
            and value.get('dartVersion') == '3.11.4'
            and value.get('lockfileSha256') == lock_hash, 'Production build/configuration mismatch')


def validate_connection(directory):
    directory, manifest = session(directory)
    require(manifest['phase'] == 'web-only', 'Vercel executor requires web-only phase')
    context = request(directory, 'vercel-context', {})
    teams = [team for team in context.get('teams', []) if team.get('id') == TEAM]
    require(len(teams) == 1, 'Pinned Vercel team is unavailable')
    projects = [p for p in teams[0].get('linkedProjects', []) if p.get('id') == PROJECT]
    require(len(projects) == 1 and projects[0].get('name') == NAME
            and all(projects[0].get('link', {}).get(key) == value for key, value in
                    {'type': 'github', 'org': 'ahc0403-commits', 'repo': NAME}.items()),
            'Pinned Vercel Git connection differs')
    print('Vercel authenticated team/project/Git source: verified (no CLI credential transfer).')


def deploy(directory):
    directory, manifest = session(directory)
    arguments = deployment_arguments(manifest['sourceSha'])
    # Created exactly once. A claimed uncertain result is never resubmitted.
    write_new(directory / 'vercel-prepared.json', {'sourceSha': manifest['sourceSha'], 'arguments': arguments})
    previous = request(directory, 'vercel-inspect', {'idOrUrl': HOST, 'teamId': TEAM, 'withGitRepoInfo': 'true'})
    require(previous.get('readyState') == 'READY' and previous.get('target') == 'production',
            'Missing prior production rollback deployment')
    write_new(directory / 'vercel-rollback.json', {k: previous.get(k) for k in ('id', 'url', 'meta', 'gitSource')})
    created = request(directory, 'vercel-deploy', arguments)
    require(str(created.get('id', '')).startswith('dpl_'), 'No Vercel deployment identity returned')
    write_new(directory / 'vercel-created.json', {'id': created['id'], 'sourceSha': manifest['sourceSha']})
    identifier = created['id']
    deadline = time.monotonic() + 1800
    while True:
        value = request(directory, 'vercel-inspect', {'idOrUrl': identifier, 'teamId': TEAM, 'withGitRepoInfo': 'true'})
        require(value.get('readyState') not in {'ERROR', 'CANCELED'}, 'Vercel build failed; inspect logs, no success claim')
        if value.get('readyState') == 'READY':
            break
        require(time.monotonic() < deadline, 'Vercel build timed out; inspect actual state before continuation')
        time.sleep(5)
    verify_deployment(value, manifest['sourceSha'])
    alias = request(directory, 'vercel-inspect', {'idOrUrl': HOST, 'teamId': TEAM, 'withGitRepoInfo': 'true'})
    verify_deployment(alias, manifest['sourceSha'], identifier)
    require(value.get('url') and '/' not in value['url'] and value['url'].endswith('.vercel.app'), 'Invalid provider URL')
    build_url = LIVE + '/pos-release.json?sha=' + manifest['sourceSha']
    with urllib.request.urlopen(build_url, timeout=30) as response:
        require(response.status == 200, 'Live build attestation unavailable')
        build = json.load(response)
    lock_hash = hashlib.sha256((ROOT / 'pubspec.lock').read_bytes()).hexdigest()
    verify_build(build, manifest['sourceSha'], lock_hash)
    actual_js = hashlib.sha256()
    with urllib.request.urlopen(LIVE + '/main.dart.js?sha=' + manifest['sourceSha'], timeout=60) as response:
        while chunk := response.read(1024 * 1024):
            actual_js.update(chunk)
    require(actual_js.hexdigest() == build.get('mainDartJsSha256'), 'Live compiled JavaScript differs from source build')
    receipt = {'sourceSha': manifest['sourceSha'], 'deploymentId': identifier,
               'url': 'https://' + value['url'], 'productionUrl': LIVE,
               'providerSourceVerified': True, 'productionAliasVerified': True,
               'providerGitShaReadback': (value.get('gitSource') or {}).get('sha') == manifest['sourceSha'],
               'productionBuild': build, 'rollbackDeploymentId': previous['id']}
    write_new(directory / 'vercel-receipt.json', receipt)
    print(canonical(receipt))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['connection', 'deploy'])
    parser.add_argument('--directory', required=True)
    args = parser.parse_args()
    try:
        (validate_connection if args.action == 'connection' else deploy)(args.directory)
    except (CloudError, OSError, ValueError, KeyError) as error:
        raise SystemExit('POS_VERCEL_RELEASE_BLOCKED: ' + str(error))
