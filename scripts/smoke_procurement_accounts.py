#!/usr/bin/env python3
"""Read-only business smoke using existing operational password logins.

Credentials must be a mode-600 JSON file outside the repository, keyed by
bunsik_sm1 and bt_pr1. No password/token or business line data is printed.
"""
import argparse
import json
import os
from pathlib import Path
import stat
import time
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
TARGET = 'https://ynriuoomotxuwhuxxmhj.supabase.co'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--credentials-file', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--env-file', default=str(ROOT / '.env.local'))
    args = parser.parse_args()
    secret = Path(args.credentials_file).resolve()
    if secret.is_relative_to(ROOT) or stat.S_IMODE(secret.stat().st_mode) != 0o600:
        raise RuntimeError('Credentials require a mode-600 file outside the repository')
    credentials = json.loads(secret.read_text())
    config = dict(os.environ)
    for line in Path(args.env_file).read_text().splitlines():
        if '=' in line and not line.lstrip().startswith('#'):
            key, value = line.removeprefix('export ').split('=', 1)
            config.setdefault(key.strip(), value.strip().strip('\"\''))
    if config.get('SUPABASE_URL', '').rstrip('/') != TARGET:
        raise RuntimeError('Unexpected Supabase target')
    api_key = config['SUPABASE_ANON_KEY']
    results = []
    for code, role in [('bunsik_sm1', 'store_admin'), ('bt_pr1', 'inventory_orderer')]:
        calls = []

        def request(path, payload=None, token=None, method=None):
            data = None if payload is None else json.dumps(payload).encode()
            req = urllib.request.Request(TARGET + path, data=data, method=method,
                headers={'apikey': api_key, 'Content-Type': 'application/json',
                         **({'Authorization': 'Bearer ' + token} if token else {})})
            started = time.perf_counter()
            try:
                with urllib.request.urlopen(req, timeout=30) as response:
                    raw = response.read()
                    status_code = response.status
            except urllib.error.HTTPError as error:
                # Do not echo response bodies, request headers or credentials.
                raise RuntimeError(f'{code}: {path.split("?")[0]} HTTP {error.code}') from None
            calls.append({'path': path.split('?')[0], 'status': status_code,
                'duration_ms': round((time.perf_counter() - started) * 1000, 2),
                'response_bytes': len(raw)})
            return json.loads(raw) if raw else None

        token = None
        try:
            password = credentials.get(code)
            if not password:
                raise RuntimeError(f'Missing existing password for {code}')
            login = request('/auth/v1/token?grant_type=password',
                {'email': code + '@globos.world', 'password': password})
            token = login['access_token']
            user_id = login['user']['id']
            profile = request('/rest/v1/users?' + urllib.parse.urlencode({
                'auth_id': 'eq.' + user_id,
                'select': 'role,restaurant_id,fixed_account_code,is_active,must_change_password',
            }), token=token)
            if len(profile) != 1 or profile[0]['role'] != role or not profile[0]['is_active']:
                raise RuntimeError(f'{code}: profile mismatch')
            if profile[0]['fixed_account_code'] != code or profile[0]['must_change_password']:
                raise RuntimeError(f'{code}: fixed identity or password-change gate mismatch')
            store = profile[0]['restaurant_id']
            catalog = request('/rest/v1/rpc/get_inventory_order_catalog', {'p_store_id': store}, token)
            if not catalog.get('procurement_policy', {}).get('enabled'):
                raise RuntimeError(f'{code}: procurement is disabled')
            query = {'request_view': True, 'request_group': 'pending', 'limit': 20,
                     'request_sort': 'submitted' if role == 'store_admin' else 'created'}
            if role == 'store_admin':
                query['request_scope'] = 'mine'
            page = request('/rest/v1/rpc/procurement_workspace_page',
                {'p_store_id': store, 'p_query': query}, token)
            actor = page['actor']
            if actor['subject_id'] != user_id or actor['role'] != role or page['contract_version'] != 2:
                raise RuntimeError(f'{code}: procurement identity mismatch')
            if role == 'inventory_orderer' and (not actor['can_create'] or actor.get('can_receive')):
                raise RuntimeError(f'{code}: requester/receiver separation failed')
            pending = page.get('approval_counts', {}).get('pending', 0)
            actionable = page.get('approval_counts', {}).get('actionable', 0)
            summary = {'account': code, 'role': role, 'login': 'passed',
                'catalog': 'passed', 'list': 'passed', 'returned_requests': len(page['requests']),
                'pending': pending, 'actionable': actionable}
            if role == 'store_admin':
                if not page['requests'] or actionable < 1:
                    raise RuntimeError('Store manager must see the existing pending PRs')
                selected = next(r for r in page['requests'] if 'store_approve' in r['allowed_actions'])
                detail = request('/rest/v1/rpc/procurement_workspace_page',
                    {'p_store_id': store, 'p_query': {**query, 'request_id': selected['id']}}, token)
                if 'store_approve' not in detail['request_detail']['allowed_actions']:
                    raise RuntimeError('Store manager detail does not allow approval')
                summary['detail'] = 'passed'
                summary['selected_line_count'] = len(detail['request_detail']['lines'])
        finally:
            if token:
                request('/auth/v1/logout?scope=local', token=token, method='POST')
        summary['calls'] = calls
        results.append(summary)
    Path(args.output).write_text(json.dumps({'target': TARGET, 'accounts': results}, indent=2) + '\n')
    print(json.dumps({'status': 'passed', 'accounts': [r['account'] for r in results]}))


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, KeyError, OSError, ValueError) as error:
        raise SystemExit(str(error)) from None
