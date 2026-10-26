#!/usr/bin/env python3
"""Verify independently signed local evidence. This does not establish key custody.

The committed policy is disabled until an independent executor and protected
verifier workflow have been approved. A signature by the submitting operator
is not a substitute. No tests/builds, signing, API writes or status creation.
"""
import base64
import datetime as dt
import hashlib
import json
from pathlib import Path
import re
import shlex
import subprocess
import tempfile

DOMAIN = b'globos-pos-local-verification-v1\x00'
STATEMENT_TYPE = 'globos-pos-independent-local-verification/v1'
MAX_RECEIPT = 2 * 1024 * 1024
MAX_STATEMENT = 16384
MAX_POLICY = 16384
PROTECTED_PREFIXES = ('scripts/', 'test/', '.github/workflows/')
PROTECTED_ROOTS = {'pubspec.yaml', 'pubspec.lock', 'analysis_options.yaml', 'dart_test.yaml'}
POLICY_PATH = 'scripts/receipt_verification/trust-policy.json'
NATIVE = {'Windows build runner propagates native nonzero exit codes',
          'Windows connection probe sends no bytes and preserves spooler error'}
OPTIONAL = {'historical Deliberry -> POS -> Office data flow harness optional historical Office import read fences from external checkout'}


class Rejected(ValueError):
    pass


class NotConfigured(Rejected):
    pass


def require(value, message):
    if not value:
        raise Rejected(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def object_pairs(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'Duplicate JSON key')
        result[key] = value
    return result


def json_bytes(data, maximum):
    require(0 < len(data) <= maximum, 'Missing/oversized JSON')
    try:
        return json.loads(data.decode('utf-8'), object_pairs_hook=object_pairs,
                          parse_constant=lambda _: (_ for _ in ()).throw(Rejected('Non-finite JSON number')))
    except (UnicodeError, json.JSONDecodeError) as error:
        raise Rejected('Invalid UTF-8/JSON') from error


def read_file(path, maximum):
    path = Path(path)
    require(path.is_file() and not path.is_symlink(), 'Missing/symlink evidence')
    with path.open('rb') as stream:
        data = stream.read(maximum + 1)
    require(0 < len(data) <= maximum, 'Missing/oversized evidence')
    return data


def hex_value(value, length):
    return isinstance(value, str) and re.fullmatch('[0-9a-f]{'+str(length)+'}', value) is not None


def positive_int(value):
    return type(value) is int and value > 0


def timestamp(value):
    require(isinstance(value, str), 'Missing timestamp')
    try:
        result = dt.datetime.fromisoformat(value)
    except ValueError as error:
        raise Rejected('Invalid timestamp') from error
    require(result.tzinfo is not None and result.utcoffset() == dt.timedelta(), 'Timestamp must be UTC')
    return result


def protected_digest(hashes):
    protected = {k:v for k,v in hashes.items() if k != POLICY_PATH and
                 (k.startswith(PROTECTED_PREFIXES) or k in PROTECTED_ROOTS)}
    require(protected, 'Missing protected verification inputs')
    return digest(json.dumps(protected, sort_keys=True).encode())


def policy_ready(policy):
    require(isinstance(policy,dict), 'Policy must be an object')
    if policy.get('enabled') is not True or not policy.get('trustedExecutors'):
        raise NotConfigured('Independent executor is not configured; no production PASS can be issued')
    require(policy.get('schemaVersion') == 1, 'Unsupported policy')
    # These are approved configuration assumptions, not proof of isolation.
    require(policy.get('independentCustodyApproved') is True and
            policy.get('protectedWorkflowApproved') is True, 'Unapproved trust boundary')
    require(policy.get('repository') == 'ahc0403-commits/globospossystem', 'Unexpected policy repository')
    require(hex_value(policy.get('contractSha256'),64) and
            hex_value(policy.get('protectedInputsSha256'),64), 'Unpinned local verification policy')
    require(positive_int(policy.get('repositoryStages')) and isinstance(policy.get('minimumAssertions'),dict) and
            all(positive_int(v) for v in policy['minimumAssertions'].values()), 'Unpinned minimum assertion coverage')
    require(type(policy.get('maxAgeSeconds')) is int and 0 < policy['maxAgeSeconds'] <= 21600,
            'Invalid evidence lifetime')


def verify_signature(statement, signature, executor):
    require(len(signature) == 64, 'Expected an Ed25519 signature')
    try:
        der = base64.b64decode(executor['publicKeySpkiDerBase64'], validate=True)
    except (ValueError, KeyError) as error:
        raise Rejected('Invalid approved public key') from error
    require(len(der) == 44 and der[:12] == bytes.fromhex('302a300506032b6570032100'),
            'Only Ed25519 SubjectPublicKeyInfo is permitted')
    require(executor.get('fingerprintSha256') == digest(der), 'Public key fingerprint mismatch')
    with tempfile.TemporaryDirectory(prefix='pos-signature-verify-') as area:
        path = Path(area)
        (path/'key.der').write_bytes(der)
        (path/'message').write_bytes(DOMAIN + statement)
        (path/'signature').write_bytes(signature)
        result = subprocess.run(['openssl','pkeyutl','-verify','-pubin','-keyform','DER',
            '-inkey',str(path/'key.der'),'-rawin','-in',str(path/'message'),
            '-sigfile',str(path/'signature')],capture_output=True,timeout=10)
        require(result.returncode == 0, 'Invalid/untrusted execution signature')


def counts_valid(counts, format_name, suites=1):
    require(isinstance(counts, dict) and positive_int(counts.get('passed')) and
            type(counts.get('failed')) is int and counts['failed'] == 0, 'No completed passing assertions')
    if format_name == 'repository':
        require(counts.get('completedSuites') == 3 and positive_int(counts.get('repositoryStages')),
                'Incomplete Flutter/repository suites')
        native, optional = counts.get('notApplicableOnLinux'), counts.get('unavailableOptionalCrossRepository')
        require(isinstance(native,list) and len(native)==len(set(native)) and set(native)==NATIVE,
                'Changed native exclusions')
        require(isinstance(optional,list) and len(optional)==len(set(optional)) and set(optional)<=OPTIONAL,
                'Unknown optional exclusion')
        replayed = counts.get('reexecutedWithSqlFixture')
        require(type(replayed) is int and replayed >= 0 and
                counts.get('skipped') == replayed+len(native)+len(optional), 'Unaccounted skipped assertions')
        for key in ['deno','node']:
            counts_valid(counts.get(key),key,suites=9 if key=='deno' else 1)
        require(counts['deno'].get('completedSuites') == 9, 'Missing bootstrap/direct Edge suite')
    else:
        require(type(counts.get('skipped')) is int and counts['skipped'] == 0, 'Skipped mandatory assertions')
        if format_name in {'flutter','deno'}:
            require(counts.get('completedSuites') == suites, 'Incomplete assertion suite')


def verify(statement_data, signature, receipt_data, policy, recipe, expected, now=None):
    policy_ready(policy)  # Reject unconfigured production before parsing submitted data.
    statement = json_bytes(statement_data, MAX_STATEMENT)
    require(isinstance(statement,dict), 'Statement must be an object')
    require(statement.get('_type') == STATEMENT_TYPE, 'Wrong signature purpose')
    require(statement.get('repository') == policy['repository'] == expected['repository'], 'Cross-repository evidence')
    for key in ['headSha','baseSha']:
        require(hex_value(statement.get(key),40) and statement[key] == expected[key], 'Wrong/stale '+key)
    require(positive_int(statement.get('pullRequest')) and statement['pullRequest'] == expected['pullRequest'],
            'Wrong pull request')
    require(statement.get('receiptSha256') == digest(receipt_data), 'Receipt was altered')
    executor = next((x for x in policy['trustedExecutors']
                     if x.get('fingerprintSha256') == statement.get('executorFingerprintSha256')), None)
    require(executor is not None, 'Unapproved executor key')
    verify_signature(statement_data, signature, executor)
    value = json_bytes(receipt_data, MAX_RECEIPT)
    require(isinstance(value,dict), 'Receipt must be an object')
    require(value.get('schemaVersion') == 1 and value.get('type') == 'pos-local-verification' and
            value.get('kind') == 'candidate' and value.get('completed') is True and value.get('status') == 'PASS',
            'Unsigned/failed/incomplete local result')
    require(value.get('contractSha256') == policy['contractSha256'], 'Unapproved recipe/runner')
    source = value.get('sourceBefore')
    require(isinstance(source,dict) and source == value.get('sourceAfter') and
            source.get('sha') == expected['headSha'] and hex_value(source.get('treeSha'),40), 'Wrong/changed source')
    hashes = source.get('inputHashes')
    require(isinstance(hashes,dict) and 0 < len(hashes) <= 20000, 'Missing/oversized source manifest')
    require(all(isinstance(k,str) and not k.startswith('/') and '..' not in Path(k).parts and
                hex_value(v,64) for k,v in hashes.items()), 'Invalid source input manifest')
    require(hex_value(expected.get('policyFileSha256'),64) and
            hashes.get(POLICY_PATH)==expected['policyFileSha256'], 'Candidate changed the trusted policy; separate bootstrap/rotation review required')
    require(source.get('fingerprint') == digest(json.dumps(hashes,sort_keys=True).encode()), 'False source fingerprint')
    require(protected_digest(hashes) == policy['protectedInputsSha256'],
            'Required tests/harness/locks changed; separate policy review required')
    start, finish = timestamp(value.get('startedAt')), timestamp(value.get('finishedAt'))
    current = now or dt.datetime.now(dt.timezone.utc)
    require(start <= finish <= current and (current-finish).total_seconds() <= policy['maxAgeSeconds'],
            'Stale/future execution')
    require(statement.get('runId') == value.get('runId') and
            isinstance(value.get('runId'),str) and re.fullmatch('[0-9a-f]{32}',value['runId']), 'Wrong execution instance')
    require(timestamp(statement.get('verifiedAt')) >= finish and
            timestamp(statement['verifiedAt']) <= current, 'Invalid independent verification time')
    steps = value.get('steps')
    require(isinstance(steps,list) and len(steps)==len(recipe['steps']), 'Missing/extra mandatory steps')
    for actual,fixed in zip(steps,recipe['steps']):
        require(actual.get('id')==fixed['id'] and actual.get('argv')==fixed['argv'] and
                actual.get('commandSha256')==digest(json.dumps(fixed['argv']).encode()), 'Changed command/order')
        require(actual.get('sourceSha')==expected['headSha'] and type(actual.get('exitCode')) is int and actual['exitCode']==0, 'Failed/stale process')
        begin,end = timestamp(actual.get('startedAt')),timestamp(actual.get('finishedAt'))
        require(start <= begin <= end <= finish and type(actual.get('durationMs')) is int and
                0 <= actual['durationMs'] <= (fixed['timeoutSeconds']+30)*1000 and
                abs((end-begin).total_seconds()*1000-actual['durationMs'])<2000, 'Invalid process interval')
        require(isinstance(actual.get('command'),str) and actual['command'].endswith(shlex.join(fixed['argv'])), 'Missing/changed executed command')
        require(actual.get('log')==fixed['id']+'.log' and hex_value(actual.get('logSha256'),64), 'Missing log integrity')
        counts_valid(actual.get('counts'),fixed['format'])
        require(actual['counts']['passed'] >= policy['minimumAssertions'][fixed['id']], 'Assertion count below approved minimum')
        if fixed['format']=='repository':
            require(actual['counts']['repositoryStages']==policy['repositoryStages'], 'Missing repository stages')
    for key in ['imageBuild','toolProbe']:
        require(isinstance(value.get(key),dict) and type(value[key].get('exitCode')) is int and value[key]['exitCode']==0 and
                hex_value(value[key].get('logSha256'),64), 'Failed/missing environment proof')
    environment = value.get('environment',{})
    linux = environment.get('linux',{})
    require(linux.get('osId')=='ubuntu' and linux.get('osVersion')=='24.04' and
            linux.get('arch')=='x86_64', 'Wrong local verification OS')
    require(all(linux.get(k)==v for k,v in recipe['tools'].items()), 'Wrong verification tool')
    image=environment.get('image',{})
    require(image.get('Os')=='linux' and image.get('Architecture')=='amd64' and
            re.fullmatch('sha256:[0-9a-f]{64}',image.get('Id','')), 'Missing/wrong tool image identity')
    fixtures=environment.get('fixtureImages')
    require(isinstance(fixtures,list) and 0 < len(fixtures) <= 100 and
            all(isinstance(x,dict) and x.get('Os')=='linux' and x.get('Architecture') in {'arm64','amd64'} and
                re.fullmatch('sha256:[0-9a-f]{64}',x.get('Id','')) for x in fixtures), 'Missing/wrong fixture image identities')
    artifacts=value.get('artifacts')
    require(isinstance(artifacts,list) and 0 < len(artifacts) <= 10000, 'Missing artifact manifest')
    names=set()
    for artifact in artifacts:
        name=artifact.get('path')
        require(isinstance(name,str) and name not in names and not name.startswith('/') and
                '..' not in Path(name).parts and positive_int(artifact.get('bytes')) and
                hex_value(artifact.get('sha256'),64), 'Invalid/missing artifact digest')
        names.add(name)
    require({'artifacts/web/index.html','artifacts/web/main.dart.js','artifacts/web/flutter_bootstrap.js',
             'artifacts/web/photo_import_worker.js','nested/fixture-images.jsonl'} <= names, 'Incomplete build/fixture evidence')
    return {'verifiedHeadSha':expected['headSha'],'baseSha':expected['baseSha'],
            'receiptSha256':digest(receipt_data),'executorFingerprintSha256':statement['executorFingerprintSha256'],
            'steps':len(steps),'meaning':'Authenticated assertion by the approved independent executor; not re-execution of tests.'}
