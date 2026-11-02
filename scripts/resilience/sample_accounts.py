#!/usr/bin/env python3
"""Verify only inventoried sample identities; no account or business mutations.

Read secrets from a private, external env file. Never source it as shell code,
log HTTP bodies/headers, retry a password login, or globally revoke sessions.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from datetime import datetime, timezone

ROOT = Path(__file__).resolve().parents[2]
TARGETS = {'pos': 'ynriuoomotxuwhuxxmhj', 'office': 'raghsbaxcwrxlsacaoau'}
STORE = '3a268807-771f-4fd4-84fe-e1b0b00de40a'
ROLES = {'bunsik_sm2': 'store_admin', 'sp_1f': 'emergency_station',
         'sp_customer': 'customer_display', 'sp_kit': 'kitchen',
         'sp_order': 'inventory_orderer', 'sp_pos': 'cashier',
         'sp_pr1': 'inventory_orderer', 'sp_tray': 'emergency_station'}
MAX_BYTES = 128 * 1024


class CheckError(ValueError):
    """Only fixed, sanitized messages may be put in this exception."""
    def __init__(self, message, ambiguous=False):
        super().__init__(message)
        self.ambiguous = ambiguous


def require(condition, message):
    if not condition:
        raise CheckError(message)


def private_file(path, max_bytes=MAX_BYTES):
    path = Path(path)
    info = path.lstat()
    require(stat.S_ISREG(info.st_mode) and stat.S_IMODE(info.st_mode) == 0o600
            and info.st_uid == os.getuid(), 'Private file must be owned mode-600 regular file')
    resolved = path.resolve()
    require(not resolved.is_relative_to(ROOT), 'Private file must be outside this repository')
    require(not any((parent / '.git').exists() for parent in resolved.parents),
            'Private file must be outside every Git worktree')
    # Prevent another user replacing a private path between reads.
    for parent in resolved.parents:
        require(not (parent.stat().st_mode & 0o022) or bool(parent.stat().st_mode & stat.S_ISVTX),
                'Private file parent is writable by another user')
    require(info.st_size <= max_bytes, 'Private input exceeds size bound')
    return resolved


def read_env(path):
    config = {}
    for line in private_file(path).read_text().splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        line = line.removeprefix('export ')
        key, sep, raw = line.partition('=')
        require(sep and re.fullmatch(r'POS_SAMPLE_[A-Z0-9_]+', key) is not None,
                'Invalid private environment assignment')
        parts = shlex.split(raw, comments=False)
        require(len(parts) == 1 and key not in config, 'Invalid private environment value')
        config[key] = parts[0]
    return config


def inventory(config):
    require(config['POS_SAMPLE_PROJECT_REF'] == TARGETS['pos']
            and config['POS_SAMPLE_OFFICE_PROJECT_REF'] == TARGETS['office']
            and config['POS_SAMPLE_STORE_ID'] == STORE, 'Unexpected sample target')
    data = json.loads(private_file(config['POS_SAMPLE_METADATA_PATH']).read_text())
    stores = data.get('stores', [])
    require(len(stores) == 1 and stores[0]['id'] == STORE and stores[0]['is_active'] is True,
            'Sample store is not active in inventory')
    accounts = data['accounts']
    require(len(accounts) == len(ROLES) and {a['account_code'] for a in accounts} == set(ROLES),
            'Sample identity inventory changed; rediscover before login')
    result = []
    for account in accounts:
        code = account['account_code']
        require(account['is_active'] is True and account['auth_present'] is True
                and account['store_id'] == STORE and account['role'] == ROLES[code],
                'Sample POS identity scope mismatch')
        result.append({**account, 'target': 'pos', 'code': code})
    office = data['office_sample_accounts']
    require(len(office) == 1, 'Unexpected Office sample identity inventory')
    account = office[0]
    require(account['email'].split('@')[0] == 'sp_purchase1'
            and account['is_active'] is True and account['account_level'] == 'staff'
            and account['scope_type'] == 'store' and account['scope_ids'] == [STORE],
            'Office sample identity scope mismatch')
    mapping = data['office_store_mapping']
    require(len(mapping) == 1 and mapping[0]['status'] == 'active'
            and mapping[0]['pos_store_id'] == STORE and mapping[0]['office_store_id'] == STORE,
            'Office sample store mapping mismatch')
    result.append({**account, 'target': 'office', 'code': 'sp_purchase1', 'role': 'staff'})
    for row in result:
        require(str(uuid.UUID(row['auth_id'])) == row['auth_id']
                and str(uuid.UUID(row['profile_id'])) == row['profile_id'], 'Invalid identity UUID')
        require(re.fullmatch(r'[a-z0-9._+-]+@[a-z0-9.-]+', row['email']) is not None,
                'Invalid sample email')
    return result


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise CheckError('Redirect refused')


class Client:
    def __init__(self, target, key):
        self.url = 'https://' + TARGETS[target] + '.supabase.co'
        self.key = key
        self.calls = []
        self.opener = urllib.request.build_opener(NoRedirect)

    def allows(self, path, payload, method):
        return path.startswith(('/auth/v1/', '/rest/v1/'))

    def request(self, path, payload=None, token=None, method=None):
        require(self.allows(path, payload, method), 'Unsupported check endpoint')
        headers = {'apikey': self.key, 'Content-Type': 'application/json'}
        if token:
            headers['Authorization'] = 'Bearer ' + token
        request = urllib.request.Request(self.url + path,
            data=None if payload is None else json.dumps(payload).encode(),
            headers=headers, method=method)
        started = time.monotonic()
        record = {'path': path.split('?')[0], 'status': None, 'responseBytes': 0}
        self.calls.append(record)
        creates_session = path.startswith('/auth/v1/token?')
        try:
            with self.opener.open(request, timeout=12) as response:
                record['status'] = response.status
                raw = response.read(MAX_BYTES + 1)
            record['responseBytes'] = len(raw)
            if len(raw) > MAX_BYTES:
                raise CheckError('Sample check response exceeds size bound', ambiguous=creates_session)
            try:
                return json.loads(raw) if raw else None
            except (ValueError, UnicodeDecodeError):
                raise CheckError('Sample check returned invalid JSON', ambiguous=creates_session) from None
        except urllib.error.HTTPError as error:
            record['status'] = error.code
            error.close()
            raise CheckError('Sample check HTTP ' + str(error.code),
                             ambiguous=creates_session and error.code >= 500) from None
        except (urllib.error.URLError, TimeoutError, OSError):
            raise CheckError('Sample check transport failure; no retry attempted',
                             ambiguous=creates_session) from None
        finally:
            record['durationMs'] = round((time.monotonic() - started) * 1000, 2)


def check_account(account, password, client):
    result = {'account': account['code'], 'target': account['target'], 'role': account['role'],
              'identity': 'NOT_RUN', 'sessionCleanup': 'NOT_CREATED', 'status': 'FAIL'}
    token = None
    try:
        login = client.request('/auth/v1/token?grant_type=password',
                               {'email': account['email'], 'password': password})
        candidate = login.get('access_token') if isinstance(login, dict) else None
        if not isinstance(candidate, str) or not candidate:
            raise CheckError('Login response has no usable session', ambiguous=True)
        token = candidate
        result['sessionCleanup'] = 'PENDING'
        require(login.get('user', {}).get('id') == account['auth_id']
                and login['user'].get('email', '').lower() == account['email'].lower(),
                'Authenticated identity differs from sample inventory')
        if account['target'] == 'pos':
            table = 'users'
            columns = 'id,auth_id,role,restaurant_id,is_active,fixed_account_code,account_type,must_change_password'
        else:
            table = 'office_user_profiles'
            columns = 'id,auth_id,account_level,scope_type,scope_ids,is_active,is_suspended,credential_state'
        query = urllib.parse.urlencode({'select': columns, 'auth_id': 'eq.' + account['auth_id'], 'limit': 2})
        rows = client.request('/rest/v1/' + table + '?' + query, token=token)
        require(isinstance(rows, list) and len(rows) == 1, 'Own profile is missing or ambiguous')
        row = rows[0]
        require(row.get('id') == account['profile_id'] and row.get('auth_id') == account['auth_id']
                and row.get('is_active') is True, 'Own profile identity or active flag mismatch')
        if account['target'] == 'pos':
            require(row.get('role') == account['role'] and row.get('restaurant_id') == STORE
                    and row.get('fixed_account_code') == account['code'], 'POS role/store/code mismatch')
            require(row.get('must_change_password') is False
                    and row.get('account_type') not in (None, '', 'legacy_user'),
                    'POS credential gate requires setup')
        else:
            require(row.get('account_level') == 'staff' and row.get('scope_type') == 'store'
                    and row.get('scope_ids') == [STORE], 'Office role/store scope mismatch')
            require(row.get('is_suspended') is False and row.get('credential_state') == 'active',
                    'Office credential gate requires setup')
        result.update(identity='PASS', status='PASS')
    except (CheckError, KeyError, TypeError, AttributeError) as error:
        result['error'] = str(error) if isinstance(error, CheckError) else 'Malformed sample check response'
        if isinstance(error, CheckError) and error.ambiguous and not token:
            result['sessionCleanup'] = 'UNKNOWN'
    finally:
        if token:
            try:
                client.request('/auth/v1/logout?scope=local', token=token, method='POST')
                result['sessionCleanup'] = 'PASS_LOCAL_ONLY'
            except CheckError:
                result.update(sessionCleanup='UNKNOWN', status='FAIL')
                result['cleanupError'] = 'Local session cleanup was not confirmed; no retry attempted'
        result['calls'] = client.calls
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--env-file', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    require(not args.output.resolve().is_relative_to(ROOT), 'Keep run evidence outside the source tree')
    require(not args.output.exists() and not args.output.is_symlink(), 'Evidence output already exists')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    started = datetime.now(timezone.utc).isoformat()
    config = read_env(args.env_file)
    accounts = inventory(config)
    password = config['POS_SAMPLE_ACCOUNT_PASSWORD']
    require(bool(password), 'Sample password is absent')
    # Preflight all public client configuration before creating any sessions.
    for target in TARGETS:
        prefix = 'POS_SAMPLE_' + ('OFFICE_' if target == 'office' else '')
        require(config.get(prefix + 'URL') == 'https://' + TARGETS[target] + '.supabase.co',
                'Unexpected sample Auth URL')
        require(bool(config.get(prefix + 'PUBLISHABLE_KEY')), 'Missing sample public client key')
    results = []
    for account in accounts:  # bounded nine independent principals, concurrency one, zero retries
        prefix = 'POS_SAMPLE_' + ('OFFICE_' if account['target'] == 'office' else '')
        result = check_account(account, password, Client(account['target'], config[prefix + 'PUBLISHABLE_KEY']))
        results.append(result)
        if result['sessionCleanup'] == 'UNKNOWN':
            break  # do not accumulate sessions after an unconfirmed cleanup
    report = {'schemaVersion': 1, 'kind': 'sample-identity-readiness',
        'sourceSha': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
        'startedAt': started, 'finishedAt': datetime.now(timezone.utc).isoformat(),
        'status': 'PASS' if len(results) == len(accounts) and all(r['status'] == 'PASS' for r in results) else 'FAIL',
        'accounts': results, 'missingRequestedCodes': ['sp_sm', 'sp_printer'],
        'businessWrites': 'NOT_RUN', 'deviceSoak': 'NOT_RUN', 'permissionActions': 'NOT_RUN',
        'operationalLoginWaiver': 'UNCHANGED'}
    fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as handle:
        json.dump(report, handle, indent=2)
        handle.write('\n')
    print(json.dumps({'status': report['status'], 'checked': len(results),
                      'passed': sum(r['status'] == 'PASS' for r in results), 'output': str(args.output)}))
    return 0 if report['status'] == 'PASS' else 1


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (CheckError, KeyError, OSError, ValueError, subprocess.SubprocessError):
        sys.exit('Sample preflight failed; inspect private configuration without printing credentials')
