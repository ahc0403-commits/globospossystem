#!/usr/bin/env python3
"""Apply one reviewed source migration through MCP as one atomic SQL statement.

The original filename/version and exact source bytes are recorded atomically
with its effects. Supabase also retains its own automatically versioned
transport migration; neither row is deleted or rewritten to hide provenance.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

from bridge import ROOT, PROJECT, CloudError, canonical, digest, request, require, session


def literal(value):
    tag = '$pos_' + digest(value)[:24] + '$'
    require(tag not in value, 'SQL delimiter collision')
    return tag + value + tag


def sql_body(text):
    # Transaction control cannot execute inside the anonymous DO statement.
    # Remove only a complete outer BEGIN/COMMIT pair. Other unsupported control
    # statements fail atomically in Postgres rather than being reinterpreted.
    start = re.match(r'(?is)\A((?:\s|--[^\n]*(?:\n|$)|/\*.*?\*/)*)BEGIN\s*;', text)
    end = re.search(r'(?is)\bCOMMIT\s*;\s*\Z', text)
    if start:
        require(end is not None and end.start() >= start.end(), 'Unmatched outer transaction')
        text = text[start.end():end.start()]
    require(not re.search(r'(?m)^\s*\\', text), 'Unsupported psql command in cloud SQL')
    return text


def source_file(path, root=ROOT):
    path = Path(path).resolve()
    require(path.is_relative_to(root.resolve()) and path.is_file(), 'SQL must be in the committed source checkout')
    text = path.read_bytes().decode('utf-8')
    require(len(text.encode()) <= 4 * 1024 * 1024, 'SQL input exceeds reviewed bound')
    return path, text


def prepare(path, sha, root=ROOT):
    path, original = source_file(path, root)
    match = re.fullmatch(r'([0-9]{14})_([a-z0-9_]+)\.sql', path.name)
    require(match is not None, 'Migration requires an exact TIMESTAMP_snake_case.sql version')
    version, slug = match.groups()
    scripts = root / 'scripts'
    inputs = {str(path.relative_to(root)): hashlib.sha256(original.encode()).hexdigest()}
    stages = []
    for prefix in ('preflight', 'apply', 'verify'):
        companion = scripts / (prefix + '_' + slug + '.sql')
        if companion.is_file():
            companion, text = source_file(companion, root)
            inputs[str(companion.relative_to(root))] = digest(text)
            stages.append((prefix, sql_body(text)))
        elif prefix == 'apply':
            stages.append((prefix, sql_body(original)))
        elif prefix == 'verify':
            require('-- production-gate: self-verifying' in original.splitlines(),
                    'Missing required production postcondition verification')
    metadata = '-- POS_CLOUD_SOURCE ' + canonical({'sourceSha': sha, 'inputHashes': inputs})
    commands = '\n'.join(' EXECUTE ' + literal(text) + ';' for _, text in stages)
    source_hash = digest(original)
    query = f'''DO $pos_cloud_atomic_migration$
BEGIN
 PERFORM pg_advisory_xact_lock(hashtextextended({literal('pos-release:' + PROJECT + ':' + version)},0));
 IF current_user <> 'postgres' OR
    (session_user !~ '^cli_login_' AND session_user <> 'postgres') OR
    NOT pg_catalog.pg_has_role(session_user,'postgres','MEMBER') THEN
   RAISE EXCEPTION 'POS_PSQL_ROLE_ACTIVATION_FAILED';
 END IF;
 IF EXISTS(SELECT 1 FROM supabase_migrations.schema_migrations WHERE version={literal(version)}) THEN
   RAISE EXCEPTION 'POS_MIGRATION_ALREADY_APPLIED';
 END IF;
{commands}
 INSERT INTO supabase_migrations.schema_migrations(version,name,statements)
 VALUES({literal(version)},{literal(slug)},ARRAY[{literal(original)},{literal(metadata)}]);
 IF NOT EXISTS(SELECT 1 FROM supabase_migrations.schema_migrations
   WHERE version={literal(version)} AND name={literal(slug)}
     AND encode(sha256(convert_to(statements[1],'UTF8')),'hex')={literal(source_hash)}
     AND statements[2]={literal(metadata)}) THEN
   RAISE EXCEPTION 'POS_MIGRATION_SOURCE_HISTORY_MISMATCH';
 END IF;
END $pos_cloud_atomic_migration$;
'''
    require(query.count('$pos_cloud_atomic_migration$') == 2, 'Outer SQL delimiter collision')
    return {'version': version, 'slug': slug, 'sourceHash': source_hash,
            'metadata': metadata, 'inputHashes': inputs,
            'transportName': 'pos_cloud_' + version + '_' + source_hash,
            'query': query, 'queryHash': digest(query)}


def verify_applied(directory, prepared, versions):
    version = prepared['version']
    require(sum(row['version'] == version for row in versions) == 1, 'Source version is missing or duplicated')
    transports = [row for row in versions if row.get('name') == prepared['transportName']]
    require(len(transports) == 1, 'Missing or ambiguous Supabase transport migration')
    rows = request(directory, 'query', {'query':
        'SELECT version,name,encode(sha256(convert_to(statements[1],\'UTF8\')),\'hex\') AS source_hash,'
        'statements[2] AS source_metadata,cardinality(statements) AS statement_count '
        'FROM supabase_migrations.schema_migrations WHERE version IN ('
        + literal(version) + ',' + literal(transports[0]['version']) + ')'})['rows']
    original = [r for r in rows if r['version'] == version]
    transport = [r for r in rows if r['version'] == transports[0]['version']]
    require(len(original) == 1 and original[0]['source_hash'] == prepared['sourceHash']
            and original[0]['source_metadata'] == prepared['metadata'] and original[0]['name'] == prepared['slug']
            and original[0]['statement_count'] == 2,
            'Persisted source bytes, dependency hashes or release SHA differ')
    require(len(transport) == 1 and transport[0]['name'] == prepared['transportName']
            and transport[0]['source_hash'] == prepared['queryHash'] and transport[0]['statement_count'] == 1,
            'Persisted transport statement does not match exact original query')
    return {'version': version, 'sourceHash': prepared['sourceHash'],
                     'queryHash': prepared['queryHash'], 'transportVersion': transports[0]['version'],
                     'inputHashes': prepared['inputHashes'], 'atomic': True, 'historyVerified': True}


def apply(directory, path, source_sha=None):
    directory, manifest = session(directory)
    selected = source_sha or manifest['sourceSha']
    if selected != manifest['sourceSha']:
        from release import bound_plan
        require(manifest['phase'] == 'coordinated'
                and selected == bound_plan(directory, manifest)['migrationSourceSha'], 'Unbound migration intent SHA')
    prepared = prepare(path, selected)
    version = prepared['version']
    before = request(directory, 'migrations', {})['migrations']
    require(not any(row['version'] == version for row in before), 'Source migration is already applied')
    require(not any(row.get('name') == prepared['transportName'] for row in before), 'Transport migration replay')
    print('POS_CLOUD_MIGRATION_SOURCE=' + version + ' sha256=' + prepared['sourceHash'], flush=True)
    request(directory, 'apply', {'name': prepared['transportName'], 'query': prepared['query']})
    # Never equate a success banner with durable source/history verification.
    after = request(directory, 'migrations', {})['migrations']
    proof = verify_applied(directory, prepared, after)
    print(canonical(proof))
    return proof


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--directory', required=True)
    parser.add_argument('--migration', required=True)
    args = parser.parse_args()
    try:
        apply(args.directory, args.migration)
    except (CloudError, OSError, ValueError, KeyError) as error:
        print('POS_CLOUD_MIGRATION_BLOCKED: ' + str(error), file=sys.stderr)
        sys.exit(1)
