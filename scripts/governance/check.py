#!/usr/bin/env python3
"""Check declared change impact and evidence references; never infer business PASS.

This local, read-only gate uses committed source and bounded Git reads. It does
not contact production, execute tests, or replace runtime/SQL/security checks.
"""
import argparse
import fnmatch
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys
import tarfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
REGISTRY = 'docs/pos/governance/FEATURE_CONTRACTS.json'
CHANGE = 'docs/pos/governance/ACTIVE_CHANGE.json'
DIMENSIONS = ('nPlusOne', 'setBasedSql', 'rowsColumns', 'joinCardinality',
              'indexesPaging', 'refreshPolling', 'cacheScope', 'concurrency',
              'retryIdempotency', 'largeResults', 'repeatedAggregates')
RISK_FLAGS = ('business', 'financial', 'authorization', 'dataAccess',
              'background', 'dbContract', 'officeContract', 'files', 'native')
CONTRACTS = ('outcomes', 'tenantScope', 'readiness', 'dbCompatibility',
             'officeBoundary', 'externalEffects', 'resourceLifetime', 'filesAndHardware')


class GovernanceError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise GovernanceError(message)


def git(root, *args):
    return subprocess.check_output(['git', *args], cwd=root, timeout=30,
                                   stderr=subprocess.PIPE)


def relative(path):
    require(isinstance(path, str) and path and '\\' not in path and
            not PurePosixPath(path).is_absolute() and
            all(part not in ('.', '..') for part in path.split('/')),
            'Invalid repository path: ' + str(path))
    return path


def repository_file(root, name):
    path = root / relative(name)
    require(path.resolve().is_relative_to(root.resolve()), 'Path escapes repository: ' + name)
    return path


def load(root, name):
    return json.loads(repository_file(root, name).read_text())


def digest(path):
    if not path.exists() and not path.is_symlink():
        return None
    data = os.readlink(path).encode() if path.is_symlink() else path.read_bytes()
    mode = '120000' if path.is_symlink() else ('100755' if path.stat().st_mode & stat.S_IXUSR else '100644')
    return {'sha256': hashlib.sha256(data).hexdigest(), 'mode': mode}


def changed_inputs(root, base):
    require(re.fullmatch('[a-f0-9]{40}', base or '') is not None, 'A full base SHA is required')
    require(subprocess.run(['git', 'merge-base', '--is-ancestor', base, 'HEAD'],
                           cwd=root, capture_output=True).returncode == 0,
            'Change base must be an ancestor of HEAD')
    names = set(git(root, 'diff', '--name-only', '--no-renames', '-z', base).decode().split('\0'))
    names.update(git(root, 'ls-files', '--others', '--exclude-standard', '-z').decode().split('\0'))
    return {name: digest(repository_file(root, name))
            for name in sorted(names - {'', CHANGE})}


def source_files(root, base=None):
    if base:
        raw = git(root, 'archive', base, 'lib')
        require(len(raw) <= 64 * 1024 * 1024, 'Base Dart source exceeds reviewed bound')
        with tarfile.open(fileobj=io.BytesIO(raw)) as archive:
            return {item.name: archive.extractfile(item).read().decode()
                    for item in archive if item.isfile() and item.name.endswith('.dart')}
    names = git(root, 'ls-files', '--cached', '--others', '--exclude-standard', '-z', 'lib').decode().split('\0')
    require(len(names) <= 20000, 'Source inventory exceeds reviewed bound')
    return {name: repository_file(root, name).read_text()
            for name in names if name.endswith('.dart') and repository_file(root, name).is_file()}


def reverse_imports(files, package):
    graph = {}
    for consumer, text in files.items():
        for directive in re.findall(r'\b(?:import|export|part(?!\s+of\b))\s+([^;]+);', text):
            for uri in re.findall(r"['\"]([^'\"]+)['\"]", directive):
                if uri.startswith('package:' + package + '/'):
                    dependency = 'lib/' + uri.split('/', 1)[1]
                elif ':' not in uri:
                    dependency = os.path.normpath(str(PurePosixPath(consumer).parent / uri))
                else:
                    continue
                if dependency in files:
                    graph.setdefault(dependency, set()).add(consumer)
    return graph


def affected(root, inputs, registry, base):
    features = {row['id'] for row in registry['features']}
    required = set()
    areas = set()
    paths = set(inputs)
    for name in paths:
        parts = name.split('/')
        if len(parts) > 2 and parts[:2] == ['lib', 'features']:
            required.add(parts[2])
        for area in registry['sharedAreas']:
            if any(fnmatch.fnmatchcase(name, pattern) for pattern in area['paths']):
                areas.add(area['id'])
                if area['affectsAllFeatures']:
                    required.update(features)
    if any(name.startswith('lib/') and name.endswith('.dart') for name in paths):
        graph = reverse_imports(source_files(root), registry['dartPackage'])
        for dependency, consumers in reverse_imports(source_files(root, base), registry['dartPackage']).items():
            graph.setdefault(dependency, set()).update(consumers)
        visited = set(paths)
        pending = list(paths)
        while pending:
            for consumer in graph.get(pending.pop(), ()):
                if consumer not in visited:
                    visited.add(consumer)
                    pending.append(consumer)
        for name in visited:
            parts = name.split('/')
            if len(parts) > 2 and parts[:2] == ['lib', 'features']:
                required.add(parts[2])
    return required, areas


def validate_registry(root, registry):
    require(registry.get('schemaVersion') == 1, 'Unsupported governance registry version')
    rows = registry.get('features', [])
    actual = {p.name for p in (root / 'lib/features').iterdir() if p.is_dir()}
    ids = [row['id'] for row in rows]
    require(len(ids) == len(set(ids)) and set(ids) == actual,
            'Feature inventory mismatch; missing=' + str(sorted(actual - set(ids))))
    checks = registry['checks']
    for key, check in checks.items():
        require(key and repository_file(root, check['path']).is_file(), 'Missing verification source: ' + key)
    for row in rows:
        require(row.get('owner') and row.get('checks'), 'Feature owner/checks missing: ' + row['id'])
        require(set(row['checks']) <= checks.keys(), 'Unknown feature verification: ' + row['id'])
        require(row.get('adoption') in ('legacy_or_partial', 'retired'),
                'Inventory registration is not proof of full feature adoption: ' + row['id'])
    streams = registry.get('workstreams', [])
    require({row['id'] for row in streams} == {'G' + str(i) for i in range(8)} and len(streams) == 8,
            'All eight remaining workstreams must be tracked')
    for row in streams:
        require(row.get('status') in ('open', 'in_progress', 'implemented'),
                'Verified/operational completion belongs to validated external evidence, not inventory checkboxes')
        require(row.get('requiredEvidence'), 'Workstream evidence requirements missing: ' + row['id'])


def validate(root=ROOT):
    root = Path(root)
    registry = load(root, REGISTRY)
    validate_registry(root, registry)
    change = load(root, CHANGE)
    require(change.get('schemaVersion') == 1, 'Unsupported change-impact version')
    inputs = changed_inputs(root, change.get('baseSha'))
    require(inputs and change.get('inputs') == inputs,
            'Change inputs are missing or stale; refresh ACTIVE_CHANGE input hashes and review impact')
    expected, areas = affected(root, inputs, registry, change['baseSha'])
    declared = change.get('affectedFeatures', [])
    require(len(declared) == len(set(declared)) and set(declared) <= {r['id'] for r in registry['features']},
            'Unknown or duplicate declared feature')
    require(expected <= set(declared), 'Missing affected features: ' + str(sorted(expected - set(declared))))
    require(areas <= set(change.get('sharedAreas', [])), 'Missing shared-area impact: ' + str(sorted(areas)))
    require(set(change.get('sharedAreas', [])) <= {r['id'] for r in registry['sharedAreas']},
            'Unknown shared-area impact')
    application = any(name.startswith(('lib/', 'supabase/', 'web/', 'assets/', 'packages/',
                                      'android/', 'ios/', 'macos/', 'linux/', 'windows/')) for name in inputs)
    kind = change.get('kind')
    require(kind in ('documentation', 'tooling', 'application'), 'Unknown change kind')
    require(not application or kind == 'application', 'Product source cannot be classified as tooling/documentation')
    require(kind != 'documentation' or all(name.endswith(('.md', '.txt')) for name in inputs),
            'Executable changes cannot be classified as documentation')
    selected = change.get('requiredChecks', [])
    require(selected and set(selected) <= registry['checks'].keys(), 'Missing/unknown required verification')
    require(not application or 'official-full-recipe' in selected, 'Application changes require the official full recipe')
    require(not any(name.startswith('scripts/governance/') for name in inputs) or 'governance-unit' in selected,
            'Governance changes require their executable negative tests')
    require(change.get('summary') and change.get('businessInvariants') and change.get('rollback'),
            'Summary, invariant and rollback review are mandatory')
    risks = change.get('risk', {})
    require(set(risks) == set(RISK_FLAGS) and all(type(v) is bool for v in risks.values()), 'Incomplete risk assessment')
    require('database' not in areas or risks['dbContract'], 'SQL changes require DB-contract review')
    require(not application or risks['business'], 'Application changes require business-impact review')
    data_access = any(name.startswith('supabase/') or
                      (name.endswith('.dart') and ('/services/' in name or '/repositories/' in name
                                                  or name.endswith('_provider.dart'))) for name in inputs)
    require(not data_access or risks['dataAccess'], 'Data paths require explicit data-access review')
    contracts = change.get('contractReview', {})
    require(set(contracts) == set(CONTRACTS), 'Outcome/scope/readiness/compatibility/lifetime review is incomplete')
    for key, row in contracts.items():
        require(type(row.get('applicable')) is bool and isinstance(row.get('reason'), str)
                and len(row['reason'].strip()) >= 12, 'Missing contract rationale: ' + key)
        if row['applicable']:
            require(row.get('checks') and set(row['checks']) <= set(selected),
                    'Applicable contracts must reference selected checks: ' + key)
    review = change.get('dataAccessReview', {})
    require(set(review) == set(DIMENSIONS), 'All eleven data/performance dimensions must be reviewed')
    for key, row in review.items():
        require(type(row.get('applicable')) is bool and isinstance(row.get('reason'), str)
                and len(row['reason'].strip()) >= 12, 'Missing data-access rationale: ' + key)
        if row['applicable']:
            require(row.get('scale') and row.get('verification'), 'Applicable dimensions need scale and verification: ' + key)
    require(set(change.get('claims', {})) == {'allPlanComplete', 'performanceImproved'}
            and change['claims']['allPlanComplete'] is False
            and change['claims']['performanceImproved'] is False,
            'Impact declarations cannot assert whole-plan completion or measured performance improvement')
    return {'status': 'PASS', 'kind': kind, 'featuresTracked': len(registry['features']),
            'affectedFeatures': sorted(declared), 'sharedAreas': sorted(areas),
            'requiredChecks': selected, 'productCompletion': False,
            'meaning': 'Impact/catalog integrity only; runtime checks and operational evidence remain required'}


def refresh(root=ROOT):
    root = Path(root)
    change = load(root, CHANGE)
    change['inputs'] = changed_inputs(root, change.get('baseSha'))
    repository_file(root, CHANGE).write_text(json.dumps(change, ensure_ascii=False, indent=2) + '\n')
    print('Input hashes refreshed; impact, risks and verification still require review.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=ROOT)
    parser.add_argument('--refresh-inputs', action='store_true')
    args = parser.parse_args()
    try:
        if args.refresh_inputs:
            refresh(args.root)
        else:
            print('POS_CHANGE_GOVERNANCE=' + json.dumps(validate(args.root), ensure_ascii=False, sort_keys=True))
    except (GovernanceError, OSError, KeyError, TypeError, json.JSONDecodeError, subprocess.SubprocessError) as error:
        print('POS_CHANGE_GOVERNANCE_BLOCKED: ' + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
