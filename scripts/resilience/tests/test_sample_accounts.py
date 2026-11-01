import copy
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('sample_accounts', Path(__file__).parents[1] / 'sample_accounts.py')
m = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(m)
AUTH = '00000000-0000-4000-8000-000000000001'
PROFILE = '00000000-0000-4000-8000-000000000002'


def account(target='pos'):
    return {'target': target, 'code': 'sp_pos' if target == 'pos' else 'sp_purchase1',
            'email': 'sample@example.test', 'auth_id': AUTH, 'profile_id': PROFILE,
            'role': 'cashier' if target == 'pos' else 'staff'}


def profile(target='pos'):
    return {'id': PROFILE, 'auth_id': AUTH, 'role': 'cashier', 'restaurant_id': m.STORE,
            'is_active': True, 'fixed_account_code': 'sp_pos', 'account_type': 'cashier',
            'must_change_password': False, 'account_level': 'staff', 'scope_type': 'store',
            'scope_ids': [m.STORE], 'is_suspended': False, 'credential_state': 'active'}


class FakeClient:
    def __init__(self, rows=None, login=None, login_error=None, logout_error=None, read_error=None):
        self.rows = rows if rows is not None else [profile()]
        self.login = login if login is not None else {'access_token': 'private-session-sentinel',
            'refresh_token': 'private-refresh-sentinel', 'user': {'id': AUTH, 'email': 'sample@example.test'}}
        self.login_error, self.logout_error, self.read_error = login_error, logout_error, read_error
        self.calls = []

    def request(self, path, payload=None, token=None, method=None):
        self.calls.append({'path': path.split('?')[0]})
        if '/token?' in path:
            if self.login_error:
                raise m.CheckError('Sample check HTTP 400')
            return self.login
        if '/logout?' in path:
            if path != '/auth/v1/logout?scope=local' or method != 'POST':
                raise AssertionError('Global/other logout is forbidden')
            if self.logout_error:
                raise m.CheckError('Sample check transport failure; no retry attempted')
            return None
        if self.read_error:
            raise m.CheckError('Sample check HTTP 403')
        if 'limit=2' not in path:
            raise AssertionError('Own profile lookup must be bounded and detect duplicates')
        return self.rows


class SampleAccountsTest(unittest.TestCase):
    def test_pos_identity_and_local_cleanup(self):
        client = FakeClient()
        result = m.check_account(account(), 'private-password-sentinel', client)
        self.assertEqual(result['status'], 'PASS')
        self.assertEqual(result['sessionCleanup'], 'PASS_LOCAL_ONLY')
        self.assertEqual(len(client.calls), 3)
        self.assertNotIn('sentinel', json.dumps(result))

    def test_office_identity_uses_own_store_scope(self):
        result = m.check_account(account('office'), 'unused', FakeClient())
        self.assertEqual(result['status'], 'PASS')
        self.assertEqual(result['calls'][1]['path'], '/rest/v1/office_user_profiles')

    def test_login_rejection_is_not_retried(self):
        client = FakeClient(login_error=True)
        result = m.check_account(account(), 'unused', client)
        self.assertEqual(result['status'], 'FAIL')
        self.assertEqual(result['sessionCleanup'], 'NOT_CREATED')
        self.assertEqual(len(client.calls), 1)

    def test_wrong_authenticated_actor_still_cleans_local_session(self):
        login = copy.deepcopy(FakeClient().login)
        login['user']['id'] = PROFILE
        result = m.check_account(account(), 'unused', FakeClient(login=login))
        self.assertEqual(result['status'], 'FAIL')
        self.assertEqual(result['sessionCleanup'], 'PASS_LOCAL_ONLY')
        self.assertEqual(len(result['calls']), 2)

    def test_ambiguous_login_result_is_not_treated_as_session_absent(self):
        client = FakeClient(login={'user': {'id': AUTH}, 'access_token': []})
        result = m.check_account(account(), 'unused', client)
        self.assertEqual(result['status'], 'FAIL')
        self.assertEqual(result['sessionCleanup'], 'UNKNOWN')
        self.assertEqual(len(client.calls), 1)

    def test_transport_loss_during_login_records_unknown(self):
        client = FakeClient()
        def lost_response(*args, **kwargs):
            client.calls.append({'path': '/auth/v1/token'})
            raise m.CheckError('Sample check transport failure; no retry attempted', ambiguous=True)
        client.request = lost_response
        result = m.check_account(account(), 'unused', client)
        self.assertEqual(result['sessionCleanup'], 'UNKNOWN')
        self.assertEqual(len(client.calls), 1)

    def test_read_failure_is_not_successful_identity(self):
        result = m.check_account(account(), 'unused', FakeClient(read_error=True))
        self.assertEqual(result['identity'], 'NOT_RUN')
        self.assertEqual(result['status'], 'FAIL')
        self.assertEqual(result['sessionCleanup'], 'PASS_LOCAL_ONLY')

    def test_duplicate_or_missing_profiles_fail(self):
        for rows in ([], [profile(), profile()]):
            with self.subTest(count=len(rows)):
                self.assertEqual(m.check_account(account(), 'unused', FakeClient(rows=rows))['status'], 'FAIL')

    def test_role_actor_store_active_and_credential_drift_fail(self):
        for key, value in [('role', 'store_admin'), ('restaurant_id', PROFILE),
                           ('id', AUTH), ('auth_id', PROFILE), ('is_active', False),
                           ('fixed_account_code', 'other'), ('must_change_password', True),
                           ('account_type', 'legacy_user')]:
            row = profile()
            row[key] = value
            with self.subTest(key=key):
                result = m.check_account(account(), 'unused', FakeClient(rows=[row]))
                self.assertEqual(result['status'], 'FAIL')
                self.assertEqual(result['sessionCleanup'], 'PASS_LOCAL_ONLY')

    def test_office_extra_scope_or_suspension_fails(self):
        for key, value in [('scope_ids', [m.STORE, PROFILE]), ('scope_type', 'company'),
                           ('account_level', 'admin'), ('is_suspended', True),
                           ('credential_state', 'pending')]:
            row = profile()
            row[key] = value
            with self.subTest(key=key):
                self.assertEqual(m.check_account(account('office'), 'unused',
                    FakeClient(rows=[row]))['status'], 'FAIL')

    def test_cleanup_failure_does_not_claim_pass_or_retry(self):
        client = FakeClient(logout_error=True)
        result = m.check_account(account(), 'unused', client)
        self.assertEqual(result['identity'], 'PASS')
        self.assertEqual(result['sessionCleanup'], 'UNKNOWN')
        self.assertEqual(result['status'], 'FAIL')
        self.assertEqual(len(client.calls), 3)

    def test_redirects_never_forward_tokens(self):
        with self.assertRaises(m.CheckError):
            m.NoRedirect().redirect_request(None, None, 302, '', {}, 'https://other.invalid')

    def test_environment_is_parsed_without_shell_execution(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'sample.env'
            path.write_text("POS_SAMPLE_ACCOUNT_PASSWORD='$(touch unsafe); `command` !'\n")
            path.chmod(0o600)
            self.assertEqual(m.read_env(path)['POS_SAMPLE_ACCOUNT_PASSWORD'], '$(touch unsafe); `command` !')

    def test_private_file_permissions_and_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'sample.env'
            path.write_text('POS_SAMPLE_TEST=value\n')
            path.chmod(0o644)
            with self.assertRaises(m.CheckError):
                m.read_env(path)
            path.chmod(0o600)
            link = Path(directory) / 'link'
            link.symlink_to(path)
            with self.assertRaises(m.CheckError):
                m.read_env(link)

    def test_duplicate_environment_values_fail(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'sample.env'
            path.write_text('POS_SAMPLE_TEST=x\nPOS_SAMPLE_TEST=y\n')
            path.chmod(0o600)
            with self.assertRaises(m.CheckError):
                m.read_env(path)

    def test_oversize_response_is_sanitized(self):
        class Response:
            status = 200
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def read(self, bound): return b'x' * bound
        client = m.Client('pos', 'test-public-key')
        with patch.object(client.opener, 'open', return_value=Response()):
            with self.assertRaisesRegex(m.CheckError, 'size bound'):
                client.request('/auth/v1/token?grant_type=password', {'password': 'sentinel'})
        self.assertNotIn('sentinel', json.dumps(client.calls))


if __name__ == '__main__':
    unittest.main()
