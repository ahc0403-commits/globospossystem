#!/usr/bin/env python3
"""Record/compare bounded catalog evidence; not a schema dump or restore PASS."""
import argparse
from collections import Counter
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
PROJECTS = {'pos': 'ynriuoomotxuwhuxxmhj', 'office': 'raghsbaxcwrxlsacaoau'}
DETAILS = {
    'schema': {'owner', 'acl'},
    'routine': {'kind', 'owner', 'securityDefiner', 'volatility', 'strict', 'parallel', 'leakproof',
                'result', 'searchPath', 'configHash', 'definitionHash', 'acl'},
    'relation': {'kind', 'owner', 'rls', 'forceRls', 'acl', 'replicaIdentity', 'options',
                 'columnsHash', 'columnCount', 'viewHash', 'partitionHash'},
    'constraint': {'type', 'validated', 'deferrable', 'deferred', 'definitionHash'},
    'index': {'valid', 'ready', 'unique', 'primary', 'definitionHash'},
    'trigger': {'enabled', 'definitionHash'},
    'policy': {'command', 'permissive', 'roles', 'usingHash', 'checkHash'},
    'default_acl': {'acl'}, 'extension': {'version', 'schema'}, 'enum': {'labelsHash'},
    'sequence': {'type', 'start', 'increment', 'min', 'max', 'cache', 'cycle'},
    'publication': {'allTables', 'insert', 'update', 'delete', 'truncate', 'viaRoot'},
    'publication_relation': {'columns', 'filterHash'}, 'migration': {'name', 'statementsHash'},
}
MAX_BYTES = 7 * 1024 * 1024


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def pg_jsonb(value):
    """Postgres jsonb text order for our bounded non-floating catalog values."""
    if isinstance(value, dict):
        keys = sorted(value, key=lambda k: (len(k.encode()), k.encode()))
        return '{' + ', '.join(json.dumps(k, ensure_ascii=False) + ': ' + pg_jsonb(value[k]) for k in keys) + '}'
    if isinstance(value, list):
        return '[' + ', '.join(pg_jsonb(v) for v in value) + ']'
    require(value is None or type(value) in (str, int, bool), 'Unsupported catalog scalar')
    return json.dumps(value, ensure_ascii=False)


def validate(snapshot):
    require(set(snapshot) == {'schemaVersion', 'kind', 'capturedAt', 'serverVersion', 'searchPath',
            'database', 'schemas', 'objectCount', 'limitExceeded', 'objects', 'restorableSchema',
            'businessDataCollected'}, 'Unexpected catalog envelope fields')
    require(snapshot.get('schemaVersion') == 1 and snapshot.get('kind') == 'runtime-catalog',
            'Unsupported catalog envelope')
    require(snapshot.get('limitExceeded') is False, 'Catalog bound exceeded; no partial snapshot accepted')
    require(snapshot.get('restorableSchema') is False and snapshot.get('businessDataCollected') is False,
            'Catalog evidence must not claim a restorable schema or include business data')
    objects = snapshot.get('objects')
    require(isinstance(objects, list) and 0 < len(objects) <= 20000
            and snapshot.get('objectCount') == len(objects), 'Catalog count mismatch')
    seen = set()
    for row in objects:
        require(set(row) == {'kind', 'identity', 'detail', 'sha256'}, 'Unexpected catalog object fields')
        kind, identity, detail = row['kind'], row['identity'], row['detail']
        require(kind in DETAILS and isinstance(identity, str) and 0 < len(identity) <= 8192,
                'Invalid catalog object identity')
        require(isinstance(detail, dict) and set(detail) == DETAILS[kind], 'Unexpected catalog detail fields')
        require((kind, identity) not in seen, 'Duplicate catalog object identity')
        seen.add((kind, identity))
        require(row['sha256'] == digest(pg_jsonb(detail).encode()), 'Catalog object content hash mismatch')
    require(any(r['kind'] == 'migration' for r in objects), 'Migration history is missing')
    require(any(r['kind'] == 'schema' and r['identity'] == 'public' for r in objects), 'Public schema is missing')
    return snapshot


def read(path):
    raw = Path(path).read_bytes()
    require(len(raw) <= MAX_BYTES, 'Catalog evidence input exceeds bound')
    data = json.loads(raw)
    # Accept direct snapshot, one-row psql/MCP JSON, or our source-bound record.
    if isinstance(data, list):
        require(len(data) == 1 and set(data[0]) == {'snapshot'}, 'Expected exactly one catalog row')
        data = data[0]['snapshot']
    if isinstance(data, dict) and data.get('kind') == 'runtime-catalog-record':
        validate(data['snapshot'])
        require(data['catalogSha256'] == catalog_hash(data['snapshot']), 'Recorded catalog hash mismatch')
        return data
    return validate(data)


def catalog_hash(snapshot):
    ordered = sorted(snapshot['objects'], key=lambda r: (r['kind'], r['identity']))
    return digest(json.dumps(ordered, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode())


def compare(before, after):
    require(before['projectRef'] == after['projectRef'], 'Cannot compare different project scopes')
    a, b = before['snapshot'], after['snapshot']
    require(a['serverVersion'] == b['serverVersion'] and a['searchPath'] == b['searchPath'],
            'Catalog engine or search_path changed; review before comparison')
    def index(snapshot):
        return {(r['kind'], r['identity']): r['sha256'] for r in snapshot['objects']}
    left, right = index(a), index(b)
    return {'kind': 'runtime-catalog-diff', 'projectRef': before['projectRef'],
        'beforeSha256': before['catalogSha256'], 'afterSha256': after['catalogSha256'],
        'added': [list(k) for k in sorted(right.keys() - left.keys())],
        'removed': [list(k) for k in sorted(left.keys() - right.keys())],
        'changed': [list(k) for k in sorted(left.keys() & right.keys()) if left[k] != right[k]],
        'businessBehaviorVerified': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    record = sub.add_parser('record')
    record.add_argument('--project', choices=PROJECTS, required=True)
    record.add_argument('--input', type=Path, required=True)
    record.add_argument('--output', type=Path, required=True)
    diff = sub.add_parser('compare')
    diff.add_argument('--before', type=Path, required=True)
    diff.add_argument('--after', type=Path, required=True)
    args = parser.parse_args()
    if args.command == 'compare':
        print(json.dumps(compare(read(args.before), read(args.after)), ensure_ascii=False, indent=2))
        return
    snapshot = read(args.input)
    require(snapshot['kind'] == 'runtime-catalog', 'Input must be a raw catalog snapshot')
    sha = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    report = {'schemaVersion': 1, 'kind': 'runtime-catalog-record', 'projectRef': PROJECTS[args.project],
        'sourceSha': sha, 'recordedAt': datetime.now(timezone.utc).isoformat(),
        'querySha256': digest((Path(__file__).parent / 'runtime_contracts.sql').read_bytes()),
        'recorderSha256': digest(Path(__file__).read_bytes()),
        'inputSha256': digest(args.input.read_bytes()), 'catalogSha256': catalog_hash(snapshot),
        'counts': dict(sorted(Counter(r['kind'] for r in snapshot['objects']).items())),
        'freshInstall': 'NOT_RUN', 'upgradeInstall': 'NOT_RUN', 'snapshot': snapshot}
    require(not args.output.resolve().is_relative_to(ROOT), 'Evidence must stay outside source tree')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('x') as handle:
        json.dump(report, handle, ensure_ascii=False, indent=2)
        handle.write('\n')
    print(json.dumps({k: report[k] for k in ('projectRef', 'sourceSha', 'catalogSha256', 'counts')}))


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError, TypeError, subprocess.SubprocessError):
        sys.exit('Catalog evidence rejected; review input structure and bounds')
