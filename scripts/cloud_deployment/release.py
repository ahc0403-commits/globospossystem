#!/usr/bin/env python3
"""One source-bound MCP release, invoked only by the official POS deployer.

No secrets API or user session is needed. The only Edge replacement is the
already-public handler; existing JWT mode and environment inputs are retained.
Migration atomicity/source-history checks remain owned by migration.py.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

from bridge import ROOT, PROJECT, CloudError, canonical, digest, request, require, session, write_new
import migration

MIGRATIONS = (
    'supabase/migrations/20261028053422_procurement_manager_adjustment.sql',
    'supabase/migrations/20261029081324_direct_order_amendments.sql',
    'supabase/migrations/20261029084212_attendance_staff_input_recovery.sql',
)
EDGE = 'direct-order-public'
FILES = (f'supabase/functions/{EDGE}/index.ts', f'supabase/functions/{EDGE}/deno.json')
MIGRATION_SOURCE_SHA = '5e6b7452ef348dfd466e9570a918f3ac70ea28db'


def sha_file(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_plan(path, root=ROOT):
    path = Path(path)
    if not path.is_absolute():
        path = root / path
    require(not path.is_symlink(), 'Release plan cannot be a symlink')
    path = path.resolve()
    require(path.is_relative_to(root.resolve() / 'scripts/cloud_deployment/plans')
            and path.is_file() and not path.is_symlink(), 'Plan must be in the source plans directory')
    from bridge import decode
    plan = decode(path.read_text())
    require(set(plan) == {'schemaVersion', 'project', 'migrationSourceSha', 'migrations', 'edge', 'web', 'rollback'}
            and plan['schemaVersion'] == 1 and plan['project'] == PROJECT and plan['web'] is True
            and isinstance(plan['rollback'], str) and plan['rollback'], 'Invalid coordinated release plan')
    require(plan['migrationSourceSha'] == MIGRATION_SOURCE_SHA, 'Migration intent SHA changed')
    subprocess.run(['git', 'merge-base', '--is-ancestor', MIGRATION_SOURCE_SHA, 'HEAD'],
                   cwd=root, check=True, stdout=subprocess.DEVNULL)
    require([r['path'] for r in plan['migrations']] == list(MIGRATIONS),
            'Plan must retain the three reviewed migrations in order')
    edge = plan['edge']
    require(set(edge) == {'name', 'verify_jwt', 'beforeIndexSha256', 'files'}
            and edge['name'] == EDGE and edge['verify_jwt'] is False
            and re.fullmatch('[0-9a-f]{64}', edge['beforeIndexSha256'])
            and [r['path'] for r in edge['files']] == list(FILES), 'Unreviewed Edge scope or JWT change')
    for row in [*plan['migrations'], *edge['files']]:
        target = root / row['path']
        require(set(row) == {'path', 'sha256'} and target.is_file() and not target.is_symlink()
                and target.resolve().is_relative_to(root.resolve())
                and sha_file(target) == row['sha256'], 'Plan source hash/path mismatch')
    for row in plan['migrations']:
        prepared = migration.prepare(root / row['path'], MIGRATION_SOURCE_SHA, root)
        for name, expected in prepared['inputHashes'].items():
            original = subprocess.check_output(['git', 'show', MIGRATION_SOURCE_SHA + ':' + name], cwd=root)
            require(hashlib.sha256(original).hexdigest() == expected,
                    'Migration SQL/dependencies differ from the original approved intent')
    return path, plan


def payload(plan, root=ROOT):
    return {'name': EDGE, 'verify_jwt': False, 'entrypoint_path': f'{EDGE}/index.ts',
            'import_map_path': f'{EDGE}/deno.json',
            'files': [{'name': f'{EDGE}/' + Path(r['path']).name,
                       'content': (root / r['path']).read_text()} for r in plan['edge']['files']]}


def bind(directory, path):
    directory, manifest = session(directory)
    require(manifest['phase'] == 'coordinated', 'Wrong plan phase')
    path, plan = load_plan(path)
    subprocess.run(['git', 'ls-files', '--error-unmatch', str(path.relative_to(ROOT))],
                   cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
    write_new(directory / 'plan.json', {'path': str(path.relative_to(ROOT)),
              'sha256': sha_file(path), 'sourceSha': manifest['sourceSha']})


def bound_plan(directory, manifest):
    data = json.loads((directory / 'plan.json').read_text())
    path, plan = load_plan(ROOT / data['path'])
    require(data['sourceSha'] == manifest['sourceSha'] and data['sha256'] == sha_file(path),
            'Release plan changed')
    return plan


def authorize_mutation(directory, manifest, operation, arguments):
    plan = bound_plan(directory, manifest)
    if operation == 'apply':
        expected = [migration.prepare(ROOT / r['path'], plan['migrationSourceSha']) for r in plan['migrations']]
        require(any(arguments == {'name': p['transportName'], 'query': p['query']} for p in expected),
                'Mutation is not an exact planned migration')
    else:
        require(operation == 'deploy-function' and arguments == payload(plan),
                'Mutation is not the exact reviewed Edge payload')


def edge_state(directory, expected_hash):
    rows = request(directory, 'functions', {})['functions']
    matches = [row for row in rows if row.get('slug') == EDGE]
    require(len(matches) == 1 and matches[0].get('status') == 'ACTIVE'
            and matches[0].get('verify_jwt') is False, 'Existing public Edge JWT/status changed')
    remote = request(directory, 'function', {'function_slug': EDGE})
    require(remote.get('slug') == EDGE and remote.get('verify_jwt') is False
            and remote.get('version') == matches[0]['version'], 'Edge metadata/source version mismatch')
    files = remote.get('files', [])
    indexes = [f for f in files if f['name'].endswith('/index.ts') or f['name'] == 'index.ts']
    require(len(indexes) == 1 and digest(indexes[0]['content']) == expected_hash,
            'Deployed Edge source does not match reviewed source')
    return remote


def apply(directory, path):
    directory, manifest = session(directory)
    _, supplied = load_plan(path)
    plan = bound_plan(directory, manifest)
    require(supplied == plan, 'Another release plan was supplied')
    before = edge_state(directory, plan['edge']['beforeIndexSha256'])
    old = next(f['content'] for f in before['files'] if f['name'].endswith('/index.ts'))
    new = (ROOT / FILES[0]).read_text()
    # No new/renamed secret dependencies, no secret configuration mutation.
    env_names = lambda text: set(re.findall(r'Deno\.env\.get\("([A-Z0-9_]+)"\)', text))
    require(env_names(old) == env_names(new), 'Changed Edge environment contract requires separate review')
    write_new(directory / 'edge-before.json', before)
    versions = request(directory, 'migrations', {})['migrations']
    results = []
    missing_seen = False
    # Validate the whole existing prefix before any new write. An existing
    # version is reusable only with exact original SQL/metadata AND the original
    # transport statement hash. Absence alone never proves a prior success.
    for row in plan['migrations']:
        prepared = migration.prepare(ROOT / row['path'], plan['migrationSourceSha'])
        if any(r['version'] == prepared['version'] for r in versions):
            require(not missing_seen, 'Applied migrations are not an ordered prefix')
            verified = migration.verify_applied(directory, prepared, versions)
            results.append({**verified, 'status': 'ALREADY_APPLIED_VERIFIED_NOT_REEXECUTED'})
        else:
            require(not any(r.get('name') == prepared['transportName'] for r in versions),
                    'Transport exists without original source version')
            missing_seen = True
            results.append({'version': prepared['version'], 'status': 'PENDING'})
    for row, result in zip(plan['migrations'], results):
        if result['status'] == 'PENDING':
            migration.apply(directory, ROOT / row['path'], source_sha=plan['migrationSourceSha'])
            result['status'] = 'APPLIED_AND_VERIFIED'
        else:
            print('POS_CLOUD_MIGRATION=' + result['version'] + ' ALREADY_APPLIED_VERIFIED_NOT_REEXECUTED', flush=True)
    # Detect concurrent Edge replacement before writing; never blindly overwrite.
    current = edge_state(directory, plan['edge']['beforeIndexSha256'])
    require(current['version'] == before['version'], 'Concurrent Edge deployment; stop before replacement')
    request(directory, 'deploy-function', payload(plan))
    after = edge_state(directory, plan['edge']['files'][0]['sha256'])
    require(after['version'] > before['version'], 'Edge version did not advance')
    # Some historical tools omit deno.json from returned bundled files. Preserve
    # that distinction: request bytes are bound; independently compare if returned.
    maps = [f for f in after['files'] if f['name'].endswith('/deno.json')]
    if maps:
        require(len(maps) == 1 and digest(maps[0]['content']) == plan['edge']['files'][1]['sha256'],
                'Deployed import map changed')
    write_new(directory / 'coordinated-result.json', {
        'sourceSha': manifest['sourceSha'], 'migrationSourceSha': plan['migrationSourceSha'],
        'migrations': plan['migrations'], 'migrationResults': results,
        'edge': {'name': EDGE, 'beforeVersion': before['version'], 'version': after['version'],
                 'indexSha256': plan['edge']['files'][0]['sha256'], 'verify_jwt': False,
                 'importMapReturnedAndCompared': bool(maps)}, 'web': 'PENDING',
        'rollback': plan['rollback']})
    print('COORDINATED_DB_EDGE=VERIFIED; web deployment remains pending', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['validate', 'bind', 'apply'])
    parser.add_argument('--plan', required=True)
    parser.add_argument('--directory')
    args = parser.parse_args()
    try:
        if args.action == 'validate':
            load_plan(args.plan)
        elif args.action == 'bind':
            bind(args.directory, args.plan)
        else:
            apply(args.directory, args.plan)
    except (CloudError, OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print('POS_CLOUD_RELEASE_BLOCKED: ' + str(error), file=sys.stderr)
        sys.exit(1)
