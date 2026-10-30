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
    require(manifest['phase'] in {'web-only', 'integrated'}, 'Vercel write requires web-only or integrated phase')
    if manifest['phase'] == 'integrated':
        from integrated_release import require_database
        require_database(directory, manifest)
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
    # Mapped inspection may omit both gitSource and source. The initiator is
    # not a commit identity. Missing fields are recorded; a returned SHA that
    # disagrees is always fatal. Actual build SHA/lock/toolchain/bytes remain
    # mandatory before a complete deployment receipt can be written.
    require((value.get('meta') or {}).get('githubCommitSha') == sha
            and (provider_sha is None or provider_sha == sha),
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
    require(manifest['phase'] in {'web-only', 'integrated'}, 'Vercel executor requires web-only or integrated phase')
    context = request(directory, 'vercel-context', {})
    teams = [team for team in context.get('teams', []) if team.get('id') == TEAM]
    require(len(teams) == 1, 'Pinned Vercel team is unavailable')
    projects = [p for p in teams[0].get('linkedProjects', []) if p.get('id') == PROJECT]
    require(len(projects) == 1 and projects[0].get('name') == NAME
            and all(projects[0].get('link', {}).get(key) == value for key, value in
                    {'type': 'github', 'org': 'ahc0403-commits', 'repo': NAME}.items()),
            'Pinned Vercel Git connection differs')
    print('Vercel authenticated team/project/Git source: verified (no CLI credential transfer).')


def verify_live(origin, sha):
    require(origin.startswith('https://') and '/' not in origin[len('https://'):]
            and origin.endswith('.vercel.app'), 'Invalid deployment origin')
    with urllib.request.urlopen(origin + '/pos-release.json?sha=' + sha, timeout=30) as response:
        require(response.status == 200, 'Live build attestation unavailable')
        build = json.load(response)
    lock_hash = hashlib.sha256((ROOT / 'pubspec.lock').read_bytes()).hexdigest()
    verify_build(build, sha, lock_hash)
    actual_js = hashlib.sha256()
    total = 0
    with urllib.request.urlopen(origin + '/main.dart.js?sha=' + sha, timeout=60) as response:
        require(response.status == 200, 'Live compiled JavaScript unavailable')
        while chunk := response.read(1024 * 1024):
            total += len(chunk)
            require(total <= 64 * 1024 * 1024, 'Compiled JavaScript exceeds verification bound')
            actual_js.update(chunk)
    require(total > 0 and actual_js.hexdigest() == build.get('mainDartJsSha256'),
            'Live compiled JavaScript differs from source build')
    return build


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
    verify_deployment(value, manifest['sourceSha'], identifier)
    alias = request(directory, 'vercel-inspect', {'idOrUrl': HOST, 'teamId': TEAM, 'withGitRepoInfo': 'true'})
    verify_deployment(alias, manifest['sourceSha'], identifier)
    require(value.get('url') and '/' not in value['url'] and value['url'].endswith('.vercel.app'), 'Invalid provider URL')
    build = verify_live(LIVE, manifest['sourceSha'])
    receipt = {'sourceSha': manifest['sourceSha'], 'deploymentId': identifier,
               'url': 'https://' + value['url'], 'productionUrl': LIVE,
               'providerSourceVerified': True, 'productionAliasVerified': True,
               'providerGitShaReadback': (value.get('gitSource') or {}).get('sha') == manifest['sourceSha'],
               'providerGitShaStatus': 'VERIFIED' if (value.get('gitSource') or {}).get('sha') else 'NOT_RETURNED',
               'providerInitiatorReturned': value.get('source') is not None,
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
