#!/usr/bin/env python3
"""Build once with production configuration, stage, then promote after DB gates."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import time

from bridge import CloudError, canonical, require, session, write_new
import integrated_release
import vercel_release as web


def inspect(identifier):
    return json.loads(subprocess.check_output(['vercel', 'inspect', identifier, '--json'], text=True))


def stage(directory):
    directory, manifest = session(directory)
    require(manifest['phase'] == 'integrated', 'Staging requires the integrated release phase')
    integrated_release.bound_plan(directory, manifest)
    previous = inspect(web.HOST)
    require(previous.get('readyState') == 'READY' and previous.get('target') == 'production'
            and previous.get('projectId') == web.PROJECT and previous.get('id'),
            'Missing pinned production rollback deployment')
    # A failed/uncertain deploy is not blindly submitted again.
    write_new(directory / 'cli-stage-started.json', {'sourceSha': manifest['sourceSha'],
              'rollbackDeploymentId': previous['id']})
    subprocess.run(['vercel', 'build', '--prod'], check=True)
    session(directory)  # A build must not modify committed release inputs.
    output = subprocess.check_output(['vercel', 'deploy', '--prebuilt', '--prod', '--skip-domain', '--yes',
              '--meta', 'githubCommitSha=' + manifest['sourceSha'], '--meta', 'githubCommitRef=main',
              '--meta', 'githubCommitOrg=ahc0403-commits', '--meta', 'githubCommitRepo=' + web.NAME], text=True)
    urls = re.findall(r'https://[a-zA-Z0-9.-]+\.vercel\.app', output)
    require(urls, 'Staged deployment URL missing; inspect actual state before continuation')
    origin = urls[-1]
    require(origin != web.LIVE, 'Staging returned the live alias instead of a unique build')
    deployment = inspect(origin[len('https://'):])
    web.verify_deployment(deployment, manifest['sourceSha'])
    require(isinstance(deployment.get('id'), str) and deployment['id'].startswith('dpl_')
            and origin == 'https://' + deployment.get('url', ''), 'Staged identity/URL mismatch')
    # A protected unique URL without existing authorized access stops before DB
    # mutation. It is never bypassed or treated as verified.
    build = web.verify_live(origin, manifest['sourceSha'])
    require(inspect(web.HOST).get('id') == previous['id'], 'Production alias changed during staging')
    write_new(directory / 'cli-staged.json', {'sourceSha': manifest['sourceSha'],
              'deploymentId': deployment['id'], 'url': origin,
              'rollbackDeploymentId': previous['id'], 'productionBuild': build})
    print('PRODUCTION_BUILD=STAGED_VERIFIED; DB remains pending', flush=True)


def promote(directory):
    directory, manifest = session(directory)
    integrated_release.require_database(directory, manifest)
    staged = json.loads((directory / 'cli-staged.json').read_text())
    require(staged['sourceSha'] == manifest['sourceSha'], 'Staged source changed')
    web.verify_deployment(inspect(staged['deploymentId']), manifest['sourceSha'], staged['deploymentId'])
    require(inspect(web.HOST).get('id') == staged['rollbackDeploymentId'],
            'Concurrent production deployment; stop before promotion')
    write_new(directory / 'cli-promotion-started.json', {'sourceSha': manifest['sourceSha'],
              'deploymentId': staged['deploymentId']})
    subprocess.run(['vercel', 'promote', staged['url'], '--yes'], check=True)
    deadline = time.monotonic() + 120
    while True:
        alias = inspect(web.HOST)
        if alias.get('id') == staged['deploymentId']:
            break
        require(time.monotonic() < deadline, 'Production alias did not converge; inspect without redeploying')
        time.sleep(2)
    web.verify_deployment(alias, manifest['sourceSha'], staged['deploymentId'])
    build = web.verify_live(web.LIVE, manifest['sourceSha'])
    require(build == staged['productionBuild'], 'Promoted build differs from verified staged build')
    receipt = {**staged, 'productionBuild': build, 'productionUrl': web.LIVE,
               'productionAliasVerified': True, 'productionBuildCount': 1, 'promotedWithoutRebuild': True}
    write_new(directory / 'vercel-receipt.json', receipt)
    print(canonical(receipt))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['stage', 'promote'])
    parser.add_argument('--directory', required=True)
    args = parser.parse_args()
    try:
        (stage if args.action == 'stage' else promote)(args.directory)
    except (CloudError, OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        raise SystemExit('POS_CLI_WEB_BLOCKED: ' + str(error))
