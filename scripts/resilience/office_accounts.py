#!/usr/bin/env python3
"""Use the owner's private Office inventory for bounded, read-only validation.

One configured password reference, never a password reset or a role/scope grant.
Inventory all principals, select only the explicit required scope/capabilities,
and destroy only sessions created by this invocation. Never retry password login.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import urllib.parse
import uuid

import sample_accounts as shared

PROJECT = shared.TARGETS['office']
PREFIX = 'OFFICE_VALIDATION_'
MAX_INVENTORY_BYTES = 2 * 1024 * 1024
PROFILE_FIELDS = ('id,auth_id,account_level,scope_type,scope_ids,permission_model_version,'
                  'is_active,is_suspended,credential_state')


def read_env(path):
    result = {}
    for line in shared.private_file(path).read_text().splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        key, sep, raw = line.partition('=')
        shared.require(sep and re.fullmatch(PREFIX + r'[A-Z0-9_]+', key) is not None,
                       'Invalid Office environment assignment')
        parts = shlex.split(raw, comments=False)
        shared.require(len(parts) == 1 and key not in result, 'Invalid Office environment value')
        result[key] = parts[0]
    shared.require(result.get(PREFIX + 'PROJECT_REF') == PROJECT
                   and result.get(PREFIX + 'URL') == 'https://' + PROJECT + '.supabase.co',
                   'Office project mismatch')
    shared.require(bool(result.get(PREFIX + 'ACCOUNT_PASSWORD'))
                   and bool(result.get(PREFIX + 'PUBLISHABLE_KEY')), 'Office credentials are absent')
    return result


def inventory(config):
    path = shared.private_file(config[PREFIX + 'INVENTORY_PATH'], MAX_INVENTORY_BYTES)
    shared.require(hashlib.sha256(path.read_bytes()).hexdigest() == config[PREFIX + 'INVENTORY_SHA256'],
                   'Office inventory checksum mismatch; recapture before login')
    value = json.loads(path.read_text())
    shared.require(value.get('schemaVersion') == 1 and value.get('kind') == 'office-validation-inventory'
                   and value.get('projectRef') == PROJECT, 'Office inventory target mismatch')
    rows = value.get('accounts')
    shared.require(isinstance(rows, list) and 0 < len(rows) <= 1000, 'Office inventory size invalid')
    auth_ids, profile_ids = set(), set()
    for row in rows:
        for field, ids in [('auth_id', auth_ids), ('profile_id', profile_ids)]:
            identifier = row.get(field)
            if identifier is None:
                continue
            shared.require(str(uuid.UUID(identifier)) == identifier and identifier not in ids,
                           'Office identity is invalid or ambiguous')
            ids.add(identifier)
        shared.require(isinstance(row.get('effective_grants'), list), 'Office grants are missing')
        email = row.get('login_email')
        shared.require(email is None or re.fullmatch(r'[^\s@]+@[^\s@]+\.[^\s@]+', email) is not None,
                       'Office login email is invalid')
    shared.require(len(auth_ids) == value.get('authCount') and len(profile_ids) == value.get('profileCount'),
                   'Office inventory is incomplete')
    shared.require(sum(len(a['effective_grants']) for a in rows) == value.get('effectiveGrantCount'),
                   'Office inventory grant count changed')
    return rows


def ready(row):
    return (row.get('auth_present') is True and row.get('profile_present') is True
            and row.get('credential_ready') is True and row.get('is_active') is True
            and row.get('is_suspended') is False and row.get('credential_state') == 'active'
            and bool(row.get('login_email')))


def candidates(rows, capability, store_id):
    """Select from effective native grants, never infer authority from login names."""
    if capability == 'legal_admin':
        return [r for r in rows if ready(r) and r.get('account_level') in ('super_admin', 'platform_admin')
                and (r.get('permission_model_version') in ('v1', 'v2_shadow') or any(
                    g.get('domain') == 'system' and g.get('action') == 'admin'
                    and g.get('scope_level') == 'group' for g in r['effective_grants']))]
    domain, action = {'purchase': ('purchase', 'approve'), 'quality': ('quality', 'view'),
                      'finance': ('finance', 'view')}[capability]
    # Prefer store-scoped sample actors over broader administrators. Group
    # accounts are still inventoried but not substituted into a sample lane.
    return [r for r in rows if ready(r) and r.get('scope_type') == 'store'
            and r.get('scope_ids') == [store_id] and any(
                g.get('domain') == domain and g.get('action') == action
                and g.get('scope_level') == 'store' and g.get('store_id') == store_id
                for g in r['effective_grants'])]


class OfficeClient(shared.Client):
    def __init__(self, key):
        super().__init__('office', key)

    def allows(self, path, payload, method):
        if path == '/auth/v1/token?grant_type=password':
            return method in (None, 'POST')
        if path == '/auth/v1/logout?scope=local':
            return method == 'POST'
        if path.startswith('/rest/v1/office_user_profiles?'):
            return payload is None and method in (None, 'GET')
        return (path == '/functions/v1/pos-bridge' and method == 'POST'
                and isinstance(payload, dict) and payload.get('action') in
                ('config_status', 'store_mapping_diagnostics') and set(payload) == {'action'})


def check_account(account, password, client, bridge=False):
    result = {'authId': account['auth_id'], 'accountLevel': account['account_level'],
              'status': 'FAIL', 'identity': 'NOT_RUN', 'bridge': 'NOT_RUN',
              'sessionCleanup': 'NOT_CREATED'}
    token = None
    try:
        shared.require(ready(account), 'Office account is not ready')
        login = client.request('/auth/v1/token?grant_type=password',
            {'email': account['login_email'], 'password': password})
        candidate = login.get('access_token') if isinstance(login, dict) else None
        if not isinstance(candidate, str) or not candidate:
            raise shared.CheckError('Office login result is ambiguous', ambiguous=True)
        token = candidate
        result['sessionCleanup'] = 'PENDING'
        shared.require(login.get('user', {}).get('id') == account['auth_id']
                       and login['user'].get('email', '').lower() == account['login_email'].lower(),
                       'Office authenticated identity mismatch')
        query = urllib.parse.urlencode({'select': PROFILE_FIELDS,
            'auth_id': 'eq.' + account['auth_id'], 'limit': 2})
        rows = client.request('/rest/v1/office_user_profiles?' + query, token=token)
        shared.require(isinstance(rows, list) and len(rows) == 1, 'Office own profile is ambiguous')
        row = rows[0]
        for field in ('auth_id', 'account_level', 'scope_type', 'scope_ids', 'permission_model_version',
                      'is_active', 'is_suspended', 'credential_state'):
            shared.require(row.get(field) == account.get(field), 'Office live role/scope differs from inventory')
        shared.require(row.get('id') == account['profile_id'], 'Office profile identity mismatch')
        result['identity'] = 'PASS'
        if bridge:
            # Existing production bridge only. New candidate law RPCs and
            # business writes remain outside this account-readiness check.
            status = client.request('/functions/v1/pos-bridge',
                {'action': 'config_status'}, token=token, method='POST')
            shared.require(isinstance(status, dict) and status.get('configured') is True,
                           'Office POS bridge is not configured')
            result['bridge'] = 'PASS_EXISTING_CONFIG_ONLY'
        result['status'] = 'PASS'
    except (shared.CheckError, KeyError, TypeError, AttributeError) as error:
        result['error'] = str(error) if isinstance(error, shared.CheckError) else 'Office response malformed'
        if isinstance(error, shared.CheckError) and error.ambiguous and not token:
            result['sessionCleanup'] = 'UNKNOWN'
    finally:
        if token:
            try:
                client.request('/auth/v1/logout?scope=local', token=token, method='POST')
                result['sessionCleanup'] = 'PASS_LOCAL_ONLY'
            except shared.CheckError:
                result.update(sessionCleanup='UNKNOWN', status='FAIL')
                result['cleanupError'] = 'Office local session cleanup is unconfirmed; no retry attempted'
        result['calls'] = client.calls
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--env-file', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--verify-capabilities', default='',
                        help='Explicit comma-separated legal_admin,purchase,quality,finance')
    args = parser.parse_args()
    shared.require(not args.output.exists(), 'Office evidence destination already exists')
    shared.require(not any((p / '.git').exists() for p in args.output.resolve().parents),
                   'Office evidence must be external to Git')
    config = read_env(args.env_file)
    rows = inventory(config)
    requested = list(dict.fromkeys(filter(None, args.verify_capabilities.split(','))))
    shared.require(set(requested) <= {'legal_admin', 'purchase', 'quality', 'finance'},
                   'Unknown Office validation capability')
    selected, selections = {}, {}
    for capability in requested:
        found = candidates(rows, capability, config[PREFIX + 'SAMPLE_STORE_ID'])
        selections[capability] = [a['auth_id'] for a in found]
        for account in found[:1]:
            selected[account['auth_id']] = account
    started = datetime.now(timezone.utc).isoformat()
    results = []
    for account in selected.values():  # bounded <=4, one active request, zero retries
        result = check_account(account, config[PREFIX + 'ACCOUNT_PASSWORD'],
            OfficeClient(config[PREFIX + 'PUBLISHABLE_KEY']),
            bridge=account['auth_id'] in selections.get('legal_admin', []))
        results.append(result)
        if result['sessionCleanup'] == 'UNKNOWN':
            break
    passed = {r['authId'] for r in results if r['status'] == 'PASS'}
    report = {'schemaVersion': 1, 'kind': 'office-validation-readiness',
        'sourceSha': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=shared.ROOT, text=True).strip(),
        'startedAt': started, 'finishedAt': datetime.now(timezone.utc).isoformat(),
        'inventoryCount': len(rows), 'credentialReadyCount': sum(ready(a) for a in rows),
        'credentialReference': 'PRIVATE_ENV_FILE_OWNER_SUPPLIED_NOT_RESET',
        'selectionResults': {c: 'PASS' if any(a in passed for a in ids) else 'NOT_READY'
                             for c, ids in selections.items()},
        'accounts': results, 'allInventoriedPasswordsAuthenticated': False,
        'businessWrites': 'NOT_RUN', 'candidateLegalConnectionE2E': 'NOT_RUN', 'deviceSoak': 'NOT_RUN',
        'operationalLoginWaiver': 'UNCHANGED'}
    report['status'] = ('PASS_SELECTED_IDENTITIES' if requested and len(results) == len(selected)
        and all(report['selectionResults'][c] == 'PASS' for c in requested) else
        'INVENTORY_ONLY' if not requested else 'FAIL_SELECTED_IDENTITIES')
    fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as handle:
        json.dump(report, handle, indent=2)
        handle.write('\n')
    print(json.dumps({'status': report['status'], 'inventoried': len(rows),
        'verified': len(passed), 'selections': report['selectionResults'], 'output': str(args.output)}))
    return int(report['status'] == 'FAIL_SELECTED_IDENTITIES')


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (shared.CheckError, KeyError, OSError, ValueError, subprocess.SubprocessError):
        sys.exit('Office validation failed; inspect private configuration without printing credentials')
