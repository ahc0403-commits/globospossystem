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

    def test_integrated_plan_accepts_both_build_backends_and_rejects_weakened_or_mixed_scope(self):
        args = '--supabase-backend mcp --release-plan scripts/cloud_deployment/plans/20261030_integrated_pos.json --skip-login-smoke'
        for backend in ['', ' --vercel-backend mcp --mode remote']:
            result = self.shell('parse_args ' + args + backend + '; validate_cloud_options')
            self.assertEqual(result.returncode, 0, result.stderr)
        for flag in ['--skip-checks', '--skip-auth-check', '--skip-db', '--skip-build',
                     '--skip-smoke-tests', '--skip-vercel', '--no-tests', '--db-only', '--web-only',
                     '--onboarding-edge-only', '--migration arbitrary.sql']:
            result = self.shell('parse_args ' + args + ' ' + flag + '; validate_cloud_options')
            self.assertNotEqual(result.returncode, 0, flag)

    def test_connection_failure_precedes_expensive_verification(self):
        overrides = ('POS_SUPABASE_BACKEND=mcp; POS_VERCEL_BACKEND=mcp; SKIP_LOGIN_SMOKE=1; '
                     'enforce_clean_git() { :; }; enforce_origin_main_ancestry() { :; }; '
                     'initialize_cloud_execution() { echo CONNECTION; return 23; }; '
                     'enforce_local_release_contract() { echo UNEXPECTED_FULL_RUN; }; preflight')
        result = self.shell(overrides)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('CONNECTION', result.stdout)
        self.assertNotIn('UNEXPECTED_FULL_RUN', result.stdout)

    def test_covered_checks_and_local_build_do_not_execute_again(self):
        result = self.shell('FULL_RELEASE_CHECKS_VERIFIED=1; '
                            'verify_current_release_checks() { echo INTEGRITY_CHECK; }; '
                            'flutter() { echo UNEXPECTED_FLUTTER; return 99; }; '
                            'dart() { echo UNEXPECTED_DART; return 99; }; '
                            'run_checks; DEPLOY_MODE=remote; local_flutter_build')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('INTEGRITY_CHECK', result.stdout)
        self.assertIn('REUSED_PASS', result.stdout)
        self.assertNotIn('UNEXPECTED', result.stdout)
        # An inherited flag cannot manufacture this invocation's verification.
        result = self.shell('printf "%s" "$FULL_RELEASE_CHECKS_VERIFIED"',
                            {'FULL_RELEASE_CHECKS_VERIFIED': '1'})
        self.assertEqual(result.stdout, '0')

    def test_integrated_flow_orders_stage_db_promote_and_creates_no_edge_releases(self):
        common = '''
            POS_SUPABASE_BACKEND=mcp; SKIP_LOGIN_SMOKE=1;
            load_env() { :; }; ensure_flutter_env() { :; };
            verify_allowed_production_origins() { :; }; verify_vercel_firebase_web_env() { :; };
            run_auth_check() { :; }; run_checks() { echo TRACE=checks; };
            enforce_clean_git() { :; }; enforce_origin_main_ancestry() { :; };
            run() { printf 'TRACE=%s\n' "$*"; };
            deploy_vercel() { echo TRACE=web_create_once; };
            run_login_smoke() { echo TRACE=login_waiver; };
        '''
        for backend in ['cli', 'mcp']:
            result = self.shell(common + 'POS_VERCEL_BACKEND=' + backend + '; run_integrated_release_flow')
            self.assertEqual(result.returncode, 0, result.stderr)
            trace = [line for line in result.stdout.splitlines() if line.startswith('TRACE=')]
            self.assertEqual(trace.count('TRACE=checks'), 1)
            apply = next(i for i, line in enumerate(trace) if 'integrated_release.py apply' in line)
            if backend == 'cli':
                stage = next(i for i, line in enumerate(trace) if 'cli_web.py stage' in line)
                promote = next(i for i, line in enumerate(trace) if 'cli_web.py promote' in line)
                self.assertLess(stage, apply); self.assertLess(apply, promote)
                self.assertNotIn('TRACE=web_create_once', trace)
            else:
                self.assertEqual(trace.count('TRACE=web_create_once'), 1)
                self.assertLess(apply, trace.index('TRACE=web_create_once'))
            self.assertNotIn('functions deploy', result.stdout)


if __name__ == '__main__':
    unittest.main()
