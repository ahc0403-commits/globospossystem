#!/usr/bin/env python3
"""Live, run-bound IPC for the existing authenticated Supabase tool runtime.

This is an execution transport, not an external PASS/receipt importer. The
official deployer still owns source verification, stage ordering and policy.
No access token, database password or browser credential enters this bridge.
"""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import uuid

ROOT = Path(__file__).resolve().parents[2]
PROJECT = 'ynriuoomotxuwhuxxmhj'
TOOLS = {
    'project': 'supabase_get_project',
    'query': 'supabase_execute_sql',
    'migrations': 'supabase_list_migrations',
    'apply': 'supabase_apply_migration',
    'functions': 'supabase_list_edge_functions',
    'function': 'supabase_get_edge_function',
    'deploy-function': 'supabase_deploy_edge_function',
    'vercel-context': 'vercel_get_git_deployment_context',
    'vercel-inspect': 'vercel_get_deployment',
    'vercel-deploy': 'vercel_create_deployment',
}
MAX_BYTES = 8 * 1024 * 1024


class CloudError(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise CloudError(message)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False)


def wire_request(value):
    # ASCII framing gives Python and JavaScript identical character offsets,
    # including source files containing supplementary Unicode characters.
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True, allow_nan=False)


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def unique_pairs(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'Duplicate JSON member')
        result[key] = value
    return result


def decode(text):
    require(len(text.encode()) <= MAX_BYTES, 'Cloud response exceeds limit')
    def invalid_constant(_):
        raise CloudError('Non-finite JSON value')
    return json.loads(text, object_pairs_hook=unique_pairs, parse_constant=invalid_constant)


def private_directory(directory):
    directory = Path(directory).absolute()
    require(not directory.is_symlink(), 'Cloud directory must not be a symlink')
    require(not directory.resolve().is_relative_to(ROOT), 'Cloud state must be outside source checkout')
    stat = directory.stat()
    require(stat.st_uid == os.getuid() and stat.st_mode & 0o077 == 0,
            'Cloud directory must be owned by the executor with mode 0700')
    return directory


def write_new(path, value):
    temporary = path.with_name('.' + path.name + '.' + uuid.uuid4().hex)
    try:
        with open(temporary, 'x', opener=lambda p, flags: os.open(p, flags, 0o600)) as handle:
            handle.write(canonical(value) + '\n')
            handle.flush()
            os.fsync(handle.fileno())
        # Publish an entire message atomically, without replacing a prior reply.
        os.link(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def source_sha():
    return subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()


def session(directory):
    directory = private_directory(directory)
    path = directory / 'session.json'
    require(not path.is_symlink(), 'Invalid cloud manifest')
    value = decode(path.read_text())
    require(value['project'] == PROJECT and value['sourceSha'] == source_sha(),
            'Cloud source SHA or pinned project changed')
    require(value['schemaVersion'] == 1, 'Unsupported cloud protocol')
    if value['phase'] in {'db-only', 'web-only', 'coordinated'}:
        require(not subprocess.check_output(
            ['git', 'status', '--porcelain', '--untracked-files=all'], cwd=ROOT, text=True).strip(),
            'Release source changed after verification')
    return directory, value


def initialize(directory, phase):
    directory = Path(directory).absolute()
    directory.mkdir(mode=0o700, parents=False, exist_ok=False)
    private_directory(directory)
    value = {'schemaVersion': 1, 'runId': uuid.uuid4().hex,
             'sourceSha': source_sha(), 'project': PROJECT, 'phase': phase,
             'startedAt': now(), 'ownerPid': os.getppid()}
    write_new(directory / 'session.json', value)
    return value


def process_start(pid):
    try:
        stat = Path('/proc', str(pid), 'stat').read_text().rsplit(')', 1)[1].split()
        return stat[19] if stat[0] not in {'Z', 'X'} else None
    except (OSError, IndexError):
        return None


def normalize_result(raw, operation):
    require(isinstance(raw, dict) and not raw.get('isError'),
            'Authenticated cloud tool returned an error; operation must stop')
    data = raw.get('structuredContent')
    if data is None:
        content = [c['text'] for c in raw.get('content', []) if c.get('type') == 'text']
        require(len(content) == 1, 'Expected one structured Supabase result')
        data = decode(content[0])
    if isinstance(data, dict) and set(data) == {'result'} and isinstance(data['result'], dict):
        data = data['result']
    if operation == 'query':
        require(isinstance(data, dict) and isinstance(data.get('result'), str),
                'Missing SQL result boundary')
        text = data['result']
        # The preface mentions the same tag inline. Only complete boundary
        # lines frame data; neither the preface nor any cell is executable.
        require(len(re.findall(r'^<untrusted-data-[A-Za-z0-9-]+>[ \t]*\r?$', text, re.M)) == 1
                and len(re.findall(r'^</untrusted-data-[A-Za-z0-9-]+>[ \t]*\r?$', text, re.M)) == 1,
                'Missing or ambiguous SQL result boundary')
        matches = list(re.finditer(
            r'^<(untrusted-data-[A-Za-z0-9-]+)>[ \t]*\r?\n(.*?)\r?\n</\1>[ \t]*$',
            text, re.S | re.M))
        require(len(matches) == 1, 'Missing or ambiguous SQL result boundary')
        data = decode(matches[0].group(2))
        require(isinstance(data, list) and all(isinstance(x, dict) for x in data),
                'SQL result must contain rows')
        return {'rows': data}
    require(isinstance(data, dict), 'Missing Supabase operation result object')
    if operation.startswith('vercel-'):
        require(not data.get('error'), 'Vercel API returned an error; do not retry or change credentials')
        if set(data) == {'deployment'} and isinstance(data['deployment'], dict):
            data = data['deployment']
        return data
    if operation == 'project':
        require(data.get('id', data.get('ref')) == PROJECT,
                'Supabase returned another project')
        return {k: data.get(k) for k in ('id', 'name', 'status', 'region')}
    if operation == 'apply':
        require(data.get('success') is True, 'Migration tool did not confirm success')
        return {'success': True}
    if operation in ('migrations', 'functions'):
        key = 'migrations' if operation == 'migrations' else 'functions'
        require(isinstance(data.get(key), list), 'Missing remote metadata list')
    return data


def request(directory, operation, arguments, timeout=180):
    require(operation in TOOLS, 'Unsupported cloud operation')
    directory, manifest = session(directory)
    require(not (directory / 'closed.json').exists(), 'Cloud execution has ended')
    if manifest['phase'] == 'diagnostic':
        require(operation in {'project', 'query', 'migrations', 'functions', 'function'},
                'Diagnostic execution cannot apply a migration or deploy a function')
    if operation == 'vercel-deploy':
        from vercel_release import authorize_mutation
        authorize_mutation(directory, manifest, arguments)
    elif operation in {'apply', 'deploy-function'} and manifest['phase'] != 'fixture':
        if manifest['phase'] == 'coordinated':
            from release import authorize_mutation
            authorize_mutation(directory, manifest, operation, arguments)
        else:
            require(operation == 'apply' and manifest['phase'] == 'db-only',
                    'Mutation is outside the reviewed release phase')
    if operation == 'query':
        require(not re.search(r'\b(decrypted_secret|encrypted_password|refresh_token|access_token)\b',
                              arguments['query'], re.I), 'Credential extraction is forbidden')
    request_id = uuid.uuid4().hex
    item = {'schemaVersion': 1, 'requestId': request_id, 'runId': manifest['runId'],
            'sourceSha': manifest['sourceSha'], 'project': PROJECT,
            'operation': operation, 'tool': TOOLS[operation], 'arguments': arguments,
            'phase': manifest['phase'], 'ownerPid': os.getpid(),
            'ownerStart': process_start(os.getpid()),
            'expiresAt': (dt.datetime.now(dt.timezone.utc) + dt.timedelta(seconds=timeout)).isoformat(),
            'createdAt': now()}
    item['requestHash'] = digest(canonical(item))
    write_new(directory / (request_id + '.request.json'), item)
    print('POS_CLOUD_REQUEST=' + str(directory / (request_id + '.request.json')), file=sys.stderr, flush=True)
    response_path = directory / (request_id + '.response.json')
    deadline = time.monotonic() + timeout
    while not response_path.exists():
        if time.monotonic() >= deadline:
            if operation in {'apply', 'deploy-function', 'vercel-deploy'} and (directory / (request_id + '.claimed.json')).exists():
                # The connected tool may be awaiting a user's approval. Once a
                # mutation is claimed it can still execute: keep its official
                # owner alive until the actual result, rather than closing the
                # release underneath a late approval. Never invoke it again.
                waiting = directory / (request_id + '.awaiting-result.json')
                if not waiting.exists():
                    write_new(waiting, {'recordedAt': now(), 'operation': operation,
                              'status': 'CLAIMED_WAITING_FOR_ACTUAL_TOOL_RESULT'})
                    print('POS_CLOUD_AWAITING_TOOL_RESULT=' + request_id, file=sys.stderr, flush=True)
                time.sleep(0.1)
                continue
            status = 'uncertain' if (directory / (request_id + '.claimed.json')).exists() else 'cancelled'
            write_new(directory / (request_id + '.' + status + '.json'), {'recordedAt': now()})
            raise CloudError('Cloud operation timed out; determine remote state before retrying a mutation')
        time.sleep(0.1)
    require(not response_path.is_symlink(), 'Invalid cloud response path')
    reply = decode(response_path.read_text())
    for key in ('requestId', 'runId', 'sourceSha', 'project', 'requestHash', 'operation', 'tool'):
        require(reply.get(key) == item[key], 'Wrong/replayed cloud response: ' + key)
    require(reply.get('ok') is True, 'Cloud operation failed: ' + str(reply.get('error', 'unknown')))
    require(reply.get('resultHash') == digest(canonical(reply['data'])), 'Cloud result changed')
    write_new(directory / (request_id + '.accepted.json'),
              {k: reply[k] for k in ('requestId', 'requestHash', 'operation', 'resultHash', 'completedAt')})
    return reply['data']


def next_request(directory):
    directory, manifest = session(directory)
    if (directory / 'closed.json').exists():
        return {'closed': True}
    items = sorted(directory.glob('*.request.json'), key=lambda p: p.stat().st_mtime_ns)
    for path in items:
        item = decode(path.read_text())
        request_id = item['requestId']
        require(re.fullmatch(r'[a-f0-9]{32}', request_id), 'Invalid queued request ID')
        if (directory / (request_id + '.response.json')).exists():
            continue
        if any((directory / (request_id + '.' + suffix + '.json')).exists()
               for suffix in ('cancelled', 'uncertain')):
            continue
        require(dt.datetime.now(dt.timezone.utc) < dt.datetime.fromisoformat(item['expiresAt'])
                and process_start(item['ownerPid']) == item['ownerStart'] is not None,
                'Request expired or its owner ended; never start the remote operation')
        require(not (directory / (request_id + '.claimed.json')).exists(),
                'Operation already claimed; reconcile remote state rather than resubmitting')
        require(item['runId'] == manifest['runId'] and item['project'] == PROJECT
                and item['sourceSha'] == manifest['sourceSha']
                and item['phase'] == manifest['phase']
                and item['operation'] in TOOLS and item['tool'] == TOOLS[item['operation']],
                'Invalid queued operation')
        original = dict(item); expected = original.pop('requestHash')
        require(digest(canonical(original)) == expected, 'Queued request changed')
        require(path.name == request_id + '.request.json' and not path.is_symlink(),
                'Invalid queued request path')
        write_new(directory / (request_id + '.claimed.json'), {'claimedAt': now()})
        return {'request': item}
    return {'waiting': True}


def reply(directory, request_id, raw):
    directory, manifest = session(directory)
    require(re.fullmatch(r'[a-f0-9]{32}', request_id), 'Invalid request ID')
    item = decode((directory / (request_id + '.request.json')).read_text())
    require(item['runId'] == manifest['runId'], 'Wrong execution run')
    result = {k: item[k] for k in ('requestId', 'runId', 'sourceSha', 'project',
                                  'requestHash', 'operation', 'tool')}
    try:
        data = normalize_result(raw, item['operation'])
        result.update(ok=True, data=data, resultHash=digest(canonical(data)))
    except (CloudError, ValueError, KeyError, TypeError) as error:
        # Do not persist raw error output: upstream messages can include secrets.
        result.update(ok=False, error=str(error), resultHash=digest('error'))
        if isinstance(raw, dict) and raw.get('isError'):
            blocks = raw.get('content')
            blocks = blocks if isinstance(blocks, list) else []
            text = '\n'.join(c['text'] for c in blocks
                             if isinstance(c, dict) and c.get('type') == 'text'
                             and isinstance(c.get('text'), str))[:65536]
            decision = 'NOT_REPORTED'
            if re.search(r'\buser\s+(?:denied|declined|rejected)\s+(?:(?:the|this)\s+)?(?:tool\s+)?(?:call|request|operation|action)\b', text, re.I):
                decision = 'USER_DENIED'
            elif re.search(r'\bautomatic\s+approval\s+review\s+(?:rejected|denied)\b', text, re.I):
                decision = 'AUTO_REVIEW_DENIED'
            elif re.search(r'\b(?:tool\s+)?approval\s+(?:request\s+)?(?:expired|timed out)\b', text, re.I):
                decision = 'APPROVAL_EXPIRED'
            result['approvalDecision'] = decision
    result['completedAt'] = now()
    write_new(directory / (request_id + '.response.json'), result)
    return {'requestId': request_id, 'ok': result['ok']}


def request_chunk(directory, request_id, offset, length):
    directory, manifest = session(directory)
    require(re.fullmatch(r'[a-f0-9]{32}', request_id) and offset >= 0
            and 0 < length <= 12000, 'Invalid request chunk bounds')
    require((directory / (request_id + '.claimed.json')).is_file(), 'Request has not been claimed')
    path = directory / (request_id + '.request.json')
    require(not path.is_symlink(), 'Invalid request file')
    item = decode(path.read_text())
    original = dict(item); expected = original.pop('requestHash')
    require(item['runId'] == manifest['runId'] and item['sourceSha'] == manifest['sourceSha']
            and item['project'] == PROJECT and digest(canonical(original)) == expected,
            'Chunked request changed')
    text = wire_request(item)
    require(offset < len(text), 'Request chunk offset exceeds length')
    return {'chunk': text[offset:offset + length], 'length': len(text), 'requestHash': expected}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=['init', 'next', 'read-request', 'reply', 'close', 'project', 'query', 'migrations'])
    parser.add_argument('--directory', required=True)
    parser.add_argument('--phase', default='production')
    parser.add_argument('--request-id')
    parser.add_argument('--metadata-only', action='store_true')
    parser.add_argument('--offset', type=int, default=0)
    parser.add_argument('--length', type=int, default=12000)
    parser.add_argument('--file')
    args = parser.parse_args()
    if args.command == 'init':
        result = initialize(args.directory, args.phase)
    elif args.command == 'next':
        result = next_request(args.directory)
        if args.metadata_only and 'request' in result:
            item = result['request']
            result = {'requestDescriptor': {'requestId': item['requestId'],
                      'length': len(wire_request(item)), 'requestHash': item['requestHash']}}
    elif args.command == 'read-request':
        result = request_chunk(args.directory, args.request_id, args.offset, args.length)
    elif args.command == 'reply':
        result = reply(args.directory, args.request_id, decode(sys.stdin.read()))
    elif args.command == 'close':
        directory, _ = session(args.directory)
        write_new(directory / 'closed.json', {'closedAt': now()})
        result = {'closed': True}
    else:
        arguments = {'query': Path(args.file).read_text()} if args.command == 'query' else {}
        result = request(args.directory, args.command, arguments)
    print(canonical(result))


if __name__ == '__main__':
    try:
        main()
    except (CloudError, OSError, ValueError, KeyError) as error:
        print('POS_CLOUD_BLOCKED: ' + str(error), file=sys.stderr)
        sys.exit(1)
