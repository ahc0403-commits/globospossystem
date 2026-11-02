import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).parents[1]))
import office_accounts as m

AUTH = '00000000-0000-4000-8000-000000000001'
PROFILE = '00000000-0000-4000-8000-000000000002'


def account():
    return {'auth_id': AUTH, 'profile_id': PROFILE, 'login_email': 'fixture@example.invalid',
            'auth_present': True, 'profile_present': True, 'credential_ready': True,
            'is_active': True, 'is_suspended': False, 'credential_state': 'active',
            'account_level': 'platform_admin', 'scope_type': 'group', 'scope_ids': [],
            'permission_model_version': 'v2', 'effective_grants': [
                {'domain': 'system', 'action': 'admin', 'scope_level': 'group'}]}


class FakeClient:
    def __init__(self, *, changed=None, login_failure=False, ambiguous=False, logout_failure=False,
                 wrong_actor=False, bridge_ready=True):
        self.changed = changed or {}
        self.login_failure, self.ambiguous = login_failure, ambiguous
        self.logout_failure, self.wrong_actor, self.bridge_ready = logout_failure, wrong_actor, bridge_ready
        self.calls = []

    def request(self, path, payload=None, token=None, method=None):
        self.calls.append({'path': path.split('?')[0]})
        if path == '/auth/v1/token?grant_type=password':
            if self.login_failure:
                raise m.shared.CheckError('Office password rejected')
            if self.ambiguous:
                raise m.shared.CheckError('Office login response lost', ambiguous=True)
            return {'access_token': 'private-token-sentinel',
                    'user': {'id': PROFILE if self.wrong_actor else AUTH,
                             'email': 'fixture@example.invalid'}}
        if path == '/auth/v1/logout?scope=local':
            if method != 'POST':
                raise AssertionError('Local logout method required')
            if self.logout_failure:
                raise m.shared.CheckError('Local logout response lost')
            return None
        if path.startswith('/rest/v1/office_user_profiles?'):
            if 'limit=2' not in path or 'eq.' + AUTH not in path:
                raise AssertionError('Own-profile query must be scoped and bounded')
            row = account()
            row['id'] = row['profile_id']
            return [{**row, **self.changed}]
        if path == '/functions/v1/pos-bridge':
            if payload != {'action': 'config_status'}:
                raise AssertionError('Read-only bridge action required')
            return {'configured': self.bridge_ready}
        raise AssertionError('Unexpected endpoint')


class OfficeAccountsTests(unittest.TestCase):
    def test_legal_administrator_requires_native_group_permission_and_supported_role(self):
        rows = [account()]
        self.assertEqual(m.candidates(rows, 'legal_admin', m.shared.STORE), rows)
        for changes in [{'account_level': 'owner'}, {'effective_grants': []},
                        {'is_suspended': True}, {'is_active': False}, {'credential_state': 'temporary'}]:
            self.assertEqual(m.candidates([{**account(), **changes}], 'legal_admin', m.shared.STORE), [])

    def test_sample_lane_never_substitutes_a_broad_or_other_store_account(self):
        row = {**account(), 'account_level': 'staff', 'scope_type': 'store',
               'scope_ids': [m.shared.STORE], 'effective_grants': [
                   {'domain': 'purchase', 'action': 'approve', 'scope_level': 'store', 'store_id': m.shared.STORE}]}
        self.assertEqual(m.candidates([row], 'purchase', m.shared.STORE), [row])
        for changes in [{'scope_ids': [PROFILE]}, {'scope_ids': [m.shared.STORE, PROFILE]},
                        {'scope_type': 'group'}, {'effective_grants': [
                            {'domain': 'purchase', 'action': 'approve', 'scope_level': 'group'}]}]:
            self.assertEqual(m.candidates([{**row, **changes}], 'purchase', m.shared.STORE), [])

    def test_verified_identity_checks_existing_bridge_and_cleans_its_session_only(self):
        result = m.check_account(account(), 'private-password-sentinel', FakeClient(), bridge=True)
        self.assertEqual(result['status'], 'PASS')
        self.assertEqual(result['bridge'], 'PASS_EXISTING_CONFIG_ONLY')
        self.assertEqual(result['sessionCleanup'], 'PASS_LOCAL_ONLY')
        self.assertEqual(len(result['calls']), 4)
        self.assertNotIn('sentinel', json.dumps(result))

    def test_password_rejection_is_one_attempt_and_does_not_logout_existing_sessions(self):
        client = FakeClient(login_failure=True)
        result = m.check_account(account(), 'unused', client)
        self.assertEqual(result['status'], 'FAIL')
        self.assertEqual(result['sessionCleanup'], 'NOT_CREATED')
        self.assertEqual(len(client.calls), 1)

    def test_ambiguous_login_never_claims_session_absent_or_retries(self):
        client = FakeClient(ambiguous=True)
        result = m.check_account(account(), 'unused', client)
        self.assertEqual(result['sessionCleanup'], 'UNKNOWN')
        self.assertEqual(len(client.calls), 1)

    def test_wrong_actor_still_only_cleans_new_local_session(self):
        client = FakeClient(wrong_actor=True)
        result = m.check_account(account(), 'unused', client)
        self.assertEqual(result['identity'], 'NOT_RUN')
        self.assertEqual(result['sessionCleanup'], 'PASS_LOCAL_ONLY')
        self.assertEqual(len(client.calls), 2)

    def test_live_role_scope_drift_is_never_verified(self):
        for changed in [{'scope_ids': [PROFILE]}, {'account_level': 'owner'}, {'is_suspended': True},
                        {'is_active': False}, {'permission_model_version': 'v1'}, {'id': AUTH}]:
            result = m.check_account(account(), 'unused', FakeClient(changed=changed))
            self.assertEqual(result['status'], 'FAIL')
            self.assertEqual(result['sessionCleanup'], 'PASS_LOCAL_ONLY')

    def test_cleanup_failure_and_bridge_failure_are_explicit(self):
        result = m.check_account(account(), 'unused', FakeClient(logout_failure=True))
        self.assertEqual(result['status'], 'FAIL')
        self.assertEqual(result['sessionCleanup'], 'UNKNOWN')
        result = m.check_account(account(), 'unused', FakeClient(bridge_ready=False), bridge=True)
        self.assertEqual(result['identity'], 'PASS')
        self.assertEqual(result['status'], 'FAIL')
        self.assertEqual(result['sessionCleanup'], 'PASS_LOCAL_ONLY')

    def test_validator_transport_refuses_writes_and_global_logout(self):
        client = m.OfficeClient('public-test-key')
        for path, payload, method in [('/auth/v1/logout', None, 'POST'),
                ('/auth/v1/logout?scope=global', None, 'POST'),
                ('/rest/v1/office_user_profiles', {'is_active': True}, 'PATCH'),
                ('/functions/v1/pos-bridge', {'action': 'legal_connection_confirm'}, 'POST'),
                ('/functions/v1/pos-bridge', {'action': 'config_status', 'storeId': PROFILE}, 'POST')]:
            self.assertFalse(client.allows(path, payload, method))

    def test_inventory_completeness_and_duplicate_identity_guards(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'inventory.json'
            base = {'schemaVersion': 1, 'kind': 'office-validation-inventory', 'projectRef': m.PROJECT,
                    'authCount': 1, 'profileCount': 1, 'effectiveGrantCount': 1, 'accounts': [account()]}
            for change, valid in [({}, True), ({'authCount': 2}, False),
                    ({'profileCount': 0}, False), ({'effectiveGrantCount': 2}, False),
                    ({'accounts': [account(), account()]}, False)]:
                path.write_text(json.dumps({**base, **change}))
                path.chmod(0o600)
                config = {m.PREFIX + 'INVENTORY_PATH': str(path),
                          m.PREFIX + 'INVENTORY_SHA256': hashlib.sha256(path.read_bytes()).hexdigest()}
                if valid:
                    self.assertEqual(m.inventory(config), [account()])
                else:
                    with self.assertRaises(m.shared.CheckError):
                        m.inventory(config)
            config[m.PREFIX + 'INVENTORY_SHA256'] = '0' * 64
            with self.assertRaisesRegex(m.shared.CheckError, 'checksum'):
                m.inventory(config)

    def test_private_files_in_another_git_worktree_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / '.git').mkdir()
            path = root / 'private.env'
            path.write_text('synthetic only')
            path.chmod(0o600)
            with self.assertRaisesRegex(m.shared.CheckError, 'Git worktree'):
                m.shared.private_file(path)

    def test_private_env_parses_password_as_data_and_rejects_unrelated_prefix(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'office.env'
            values = {m.PREFIX + 'PROJECT_REF': m.PROJECT,
                      m.PREFIX + 'URL': 'https://' + m.PROJECT + '.supabase.co',
                      m.PREFIX + 'ACCOUNT_PASSWORD': 'synthetic-$(must-not-execute)',
                      m.PREFIX + 'PUBLISHABLE_KEY': 'public-synthetic'}
            path.write_text('\n'.join(k + '=' + m.shlex.quote(v) for k, v in values.items()))
            path.chmod(0o600)
            self.assertEqual(m.read_env(path), values)
            path.write_text(path.read_text() + '\nOTHER_ENV=value\n')
            with self.assertRaises(m.shared.CheckError):
                m.read_env(path)


if __name__ == '__main__':
    unittest.main()
