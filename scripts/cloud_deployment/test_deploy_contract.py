import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]


class DeployerContractTests(unittest.TestCase):
    def shell(self, code, env=None):
        clean = {k: v for k, v in os.environ.items() if k not in {
            'FIXED_SMOKE_ACCOUNT_CODE', 'FIXED_SMOKE_PASSWORD', 'VERCEL_PROJECT_ID',
            'VERCEL_ORG_ID', 'SUPABASE_DB_URL', 'EXPECTED_PROJECT_REF',
            'ALLOW_PROJECT_REF_MISMATCH', 'EXPECTED_VERCEL_PROJECT'}}
        return subprocess.run(['bash', '-c', 'source "$1/scripts/deploy_pos_production.sh"; ' + code,
                               'contract', str(ROOT)], env={**clean, **(env or {})},
                              text=True, capture_output=True)

    def test_reviewed_phases_succeed_but_combined_edge_scope_is_rejected(self):
        for phase in ['DB_ONLY=1', 'WEB_ONLY=1']:
            with self.subTest(phase=phase):
                self.assertEqual(self.shell('POS_SUPABASE_BACKEND=mcp; ' + phase +
                                             '; validate_cloud_options').returncode, 0)
        failed = self.shell('POS_SUPABASE_BACKEND=mcp; validate_cloud_options')
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn('Edge secret operations are unavailable', failed.stderr)

    def test_skip_flags_and_remote_build_cannot_weaken_mcp_release(self):
        for value in ['SKIP_CHECKS=1', 'SKIP_AUTH_CHECK=1', 'SKIP_LOGIN_SMOKE=1',
                      'SKIP_SMOKE_TESTS=1', 'SKIP_DB=1', 'SKIP_BUILD=1',
                      'SKIP_VERCEL=1', 'TEST_TARGETS=""', 'DEPLOY_MODE=remote']:
            with self.subTest(value=value):
                failed = self.shell('POS_SUPABASE_BACKEND=mcp; WEB_ONLY=1; ' + value +
                                    '; validate_cloud_options')
                self.assertNotEqual(failed.returncode, 0)

    def test_explicit_vercel_executor_runs_only_reviewed_web_scope_and_keeps_all_gates(self):
        args = '--supabase-backend mcp --vercel-backend mcp --web-only --mode remote --skip-login-smoke'
        good = self.shell('parse_args ' + args + '; validate_cloud_options')
        self.assertEqual(good.returncode, 0, good.stderr)
        for flag in ['--skip-checks', '--skip-auth-check', '--skip-smoke-tests', '--skip-db',
                     '--skip-build', '--skip-vercel', '--db-only', '--mode prebuilt']:
            failed = self.shell('parse_args ' + args + ' ' + flag + '; validate_cloud_options')
            self.assertNotEqual(failed.returncode, 0, flag)

    def test_missing_actual_login_credentials_stop_before_gate_or_production_tools(self):
        failed = self.shell('POS_SUPABASE_BACKEND=mcp; WEB_ONLY=1; '
                            'enforce_clean_git() { echo UNEXPECTED_GIT_GATE; }; '
                            'initialize_cloud_execution() { echo UNEXPECTED_CLOUD; }; preflight')
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn('securely supplied fixed-account login smoke', failed.stderr)
        self.assertNotIn('UNEXPECTED', failed.stdout)

    def test_existing_pinned_target_guard_is_preserved(self):
        failed = self.shell('reject_target_overrides', {'VERCEL_PROJECT_ID': 'other-project'})
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn('VERCEL_PROJECT_ID is forbidden', failed.stderr)

    def test_coordinated_scope_honors_only_explicit_login_waiver(self):
        args = '--supabase-backend mcp --cloud-release-plan scripts/cloud_deployment/plans/20261029_attendance_orders.json'
        good = self.shell('parse_args ' + args + ' --skip-login-smoke; validate_cloud_options')
        self.assertEqual(good.returncode, 0, good.stderr)
        for flag in ['--skip-checks', '--skip-auth-check', '--skip-smoke-tests',
                     '--skip-db', '--skip-build', '--skip-vercel', '--db-only',
                     '--web-only', '--onboarding-edge-only', '--mode remote']:
            failed = self.shell('parse_args ' + args + ' --skip-login-smoke ' + flag + '; validate_cloud_options')
            self.assertNotEqual(failed.returncode, 0, flag)


if __name__ == '__main__':
    unittest.main()
