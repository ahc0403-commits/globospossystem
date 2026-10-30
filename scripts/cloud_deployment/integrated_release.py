#!/usr/bin/env python3
"""Ordered DB/web plan owned by one official deployment invocation.

No Edge replacements, account changes, arbitrary SQL probes or supplied PASS
receipts are accepted. All production SQL still uses migration.py's atomic gate.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

from bridge import ROOT, PROJECT, CloudError, canonical, decode, digest, request, require, session, write_new
import migration


def load_plan(path, root=ROOT):
    path = Path(path)
    if not path.is_absolute():
        path = root / path
    require(not path.is_symlink(), 'Release plan cannot be a symlink')
    path = path.resolve()
    require(path.is_relative_to((root / 'scripts/cloud_deployment/plans').resolve())
            and path.is_file(), 'Release plan must be in the source plans directory')
    plan = decode(path.read_text())
    require(set(plan) == {'schemaVersion', 'project', 'migrations', 'contracts', 'web',
                          'backwardCompatible', 'rollback'}
            and plan['schemaVersion'] == 1 and plan['project'] == PROJECT
            and plan['web'] is True and plan['backwardCompatible'] is True
            and isinstance(plan['rollback'], str) and plan['rollback'].strip(),
            'Plan requires the pinned project, web, backward-compatible DB and rollback instructions')
    require(isinstance(plan['migrations'], list) and len(plan['migrations']) <= 50,
            'At most 50 ordered migrations are supported')
    versions = []
    for row in plan['migrations']:
        require(isinstance(row, dict) and set(row) == {'path', 'sha256'}
                and isinstance(row['path'], str)
                and re.fullmatch(r'supabase/migrations/[0-9]{14}_[a-z0-9_]+\.sql', row['path']),
                'Invalid migration path')
        target = root / row['path']
        require(not target.is_symlink() and target.resolve().is_relative_to(root.resolve())
                and target.is_file() and digest(target.read_bytes().decode('utf-8')) == row['sha256'],
                'Migration source hash/path mismatch')
        # Resolve postcondition and companion SQL before running expensive checks.
        prepared = migration.prepare(target, '0' * 40, root)
        versions.append(prepared['version'])
    require(versions == sorted(set(versions)), 'Migrations must have unique ascending dependency versions')
    require(isinstance(plan['contracts'], list) and len(plan['contracts']) <= 100,
            'At most 100 read-only function contracts are supported')
    signatures = set()
    for row in plan['contracts']:
        require(isinstance(row, dict) and set(row) == {'signature', 'resultType'}
                and isinstance(row['signature'], str)
                and re.fullmatch(r'[a-z_][a-z0-9_]*\.[a-z_][a-z0-9_]*\([a-z0-9_., \[\]]*\)', row['signature'])
                and row['signature'] not in signatures
                and isinstance(row['resultType'], str) and 0 < len(row['resultType']) <= 500,
                'Invalid or duplicate read-only function contract')
        signatures.add(row['signature'])
    return path, plan


def bind(directory, path):
    directory, manifest = session(directory)
    require(manifest['phase'] == 'integrated', 'Wrong integrated release phase')
    path, _ = load_plan(path)
    subprocess.run(['git', 'ls-files', '--error-unmatch', str(path.relative_to(ROOT))],
                   cwd=ROOT, check=True, stdout=subprocess.DEVNULL)
    write_new(directory / 'integrated-plan.json', {'path': str(path.relative_to(ROOT)),
              'sha256': digest(path.read_text()), 'sourceSha': manifest['sourceSha']})


def bound_plan(directory, manifest):
    require(manifest['phase'] == 'integrated', 'Wrong integrated release phase')
    value = decode((Path(directory) / 'integrated-plan.json').read_text())
    require(value['sourceSha'] == manifest['sourceSha'], 'Release plan belongs to another source SHA')
    path, plan = load_plan(value['path'])
    require(value['sha256'] == digest(path.read_text()), 'Release plan changed')
    return plan


def verify_contracts(directory, plan):
    if not plan['contracts']:
        return
    # The plan provides identifiers/expected types, never executable SQL.
    query = ' UNION ALL '.join(
        'SELECT ' + migration.literal(row['signature']) + ' AS signature,'
        'pg_catalog.pg_get_function_result(pg_catalog.to_regprocedure('
        + migration.literal(row['signature']) + ')) AS result_type'
        for row in plan['contracts'])
    rows = request(directory, 'query', {'query': query})['rows']
    require(len(rows) == len(plan['contracts']) and
            {row['signature']: row['result_type'] for row in rows} ==
            {row['signature']: row['resultType'] for row in plan['contracts']},
            'Production function signature/return type differs; stop before full verification')


def database_state(directory, manifest, plan):
    versions = request(directory, 'migrations', {})['migrations'] if plan['migrations'] else []
    results = []
    missing_seen = False
    for row in plan['migrations']:
        prepared = migration.prepare(ROOT / row['path'], manifest['sourceSha'])
        if any(r['version'] == prepared['version'] for r in versions):
            require(not missing_seen, 'Applied migrations must be an ordered prefix of the plan')
            # Previously applied source retains its original SHA and dependency
            # hashes. Never rewrite its history to the current release SHA.
            stored = request(directory, 'query', {'query':
                'SELECT statements[2] AS metadata FROM supabase_migrations.schema_migrations '
                'WHERE version=' + migration.literal(prepared['version'])})['rows']
            prefix = '-- POS_CLOUD_SOURCE '
            require(len(stored) == 1 and isinstance(stored[0].get('metadata'), str)
                    and stored[0]['metadata'].startswith(prefix), 'Missing original migration provenance')
            metadata = decode(stored[0]['metadata'][len(prefix):])
            require(set(metadata) == {'sourceSha', 'inputHashes'}
                    and isinstance(metadata['sourceSha'], str)
                    and re.fullmatch('[a-f0-9]{40}', metadata['sourceSha'])
                    and metadata['inputHashes'] == prepared['inputHashes'],
                    'Previously applied migration or companion SQL changed')
            require(subprocess.run(['git', 'merge-base', '--is-ancestor', metadata['sourceSha'], 'HEAD'],
                                   cwd=ROOT, capture_output=True).returncode == 0,
                    'Applied migration source is not in release ancestry')
            prepared = migration.prepare(ROOT / row['path'], metadata['sourceSha'])
            proof = migration.verify_applied(directory, prepared, versions)
            results.append({**proof, 'status': 'ALREADY_APPLIED_VERIFIED_NOT_REEXECUTED'})
        else:
            require(not any(r.get('name') == prepared['transportName'] for r in versions),
                    'Transport exists without original migration history')
            missing_seen = True
            results.append({'version': prepared['version'], 'status': 'PENDING'})
    return results


def preflight(directory):
    directory, manifest = session(directory)
    plan = bound_plan(directory, manifest)
    verify_contracts(directory, plan)
    results = database_state(directory, manifest, plan)
    write_new(directory / 'integrated-preflight.json', {'sourceSha': manifest['sourceSha'],
              'migrations': results, 'contractsVerified': len(plan['contracts'])})
    print('INTEGRATED_READ_ONLY_PREFLIGHT=PASS; migrations=' + str(len(results)), flush=True)


def apply(directory):
    directory, manifest = session(directory)
    plan = bound_plan(directory, manifest)
    require((directory / 'integrated-preflight.json').is_file(), 'Missing early production preflight')
    verify_contracts(directory, plan)
    results = database_state(directory, manifest, plan)
    write_new(directory / 'integrated-apply-started.json', {'sourceSha': manifest['sourceSha']})
    for row, result in zip(plan['migrations'], results):
        if result['status'] == 'PENDING':
            proof = migration.apply(directory, ROOT / row['path'])
            result.update(proof)
            result['status'] = 'APPLIED_AND_VERIFIED'
        else:
            print('POS_CLOUD_MIGRATION=' + result['version'] + ' ALREADY_APPLIED_VERIFIED_NOT_REEXECUTED', flush=True)
    write_new(directory / 'integrated-db-result.json', {'sourceSha': manifest['sourceSha'],
              'completed': True, 'migrations': results})
    print('INTEGRATED_DB=VERIFIED; web remains pending', flush=True)


def require_database(directory, manifest):
    plan = bound_plan(directory, manifest)
    value = decode((Path(directory) / 'integrated-db-result.json').read_text())
    require(value.get('sourceSha') == manifest['sourceSha'] and value.get('completed') is True
            and len(value['migrations']) == len(plan['migrations'])
            and all(r['version'] == Path(p['path']).name.split('_')[0]
                    and r['status'] in {'APPLIED_AND_VERIFIED', 'ALREADY_APPLIED_VERIFIED_NOT_REEXECUTED'}
                    and r['historyVerified'] is True
                    for r, p in zip(value['migrations'], plan['migrations'])),
            'Web release requires all ordered database changes to be verified')


def authorize_mutation(directory, manifest, operation, arguments):
    require(manifest['phase'] == 'integrated' and operation == 'apply', 'Unplanned integrated mutation')
    plan = bound_plan(directory, manifest)
    require((Path(directory) / 'integrated-apply-started.json').is_file(), 'DB phase has not started')
    for row in plan['migrations']:
        prepared = migration.prepare(ROOT / row['path'], manifest['sourceSha'])
        if arguments == {'name': prepared['transportName'], 'query': prepared['query']}:
            return
    raise CloudError('SQL mutation is outside the bound integrated plan')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['validate', 'bind', 'preflight', 'apply', 'require-db'])
    parser.add_argument('--plan')
    parser.add_argument('--directory')
    args = parser.parse_args()
    try:
        if args.action == 'validate':
            require(args.plan, 'Missing release plan')
            load_plan(args.plan)
        elif args.action == 'bind':
            bind(args.directory, args.plan)
        elif args.action == 'preflight':
            preflight(args.directory)
        elif args.action == 'apply':
            apply(args.directory)
        else:
            directory, manifest = session(args.directory)
            require_database(directory, manifest)
    except (CloudError, OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError) as error:
        raise SystemExit('POS_INTEGRATED_RELEASE_BLOCKED: ' + str(error))
