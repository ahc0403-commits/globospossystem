import unittest
import os
import subprocess
import reuse_candidate


class ReuseCandidateTests(unittest.TestCase):
    def test_only_complete_exact_main_production_recipe_can_be_reused(self):
        self.assertEqual(reuse_candidate.original_kind({'kind': 'candidate'}), 'candidate')
        self.assertEqual(reuse_candidate.original_kind(
            {'kind': 'exact-main', 'profile': 'production-checks'}), 'exact-main')
        for original in [{}, {'kind': 'other'}, {'kind': 'exact-main'},
                         {'kind': 'exact-main', 'profile': 'partial'}]:
            with self.subTest(original=original), self.assertRaises(reuse_candidate.gate.InvalidEvidence):
                reuse_candidate.original_kind(original)

    def shell(self, body):
        env = {k: v for k, v in os.environ.items()
               if k not in {'SUPABASE_URL', 'SUPABASE_ANON_KEY', 'ENV_FILE'}}
        script = reuse_candidate.ROOT / 'scripts/deploy_pos_production.sh'
        return subprocess.run(['bash', '-c', 'source "$1"; ENV_FILE=/dev/null; POS_SUPABASE_BACKEND=mcp; ' + body,
                               'provider-env-test', str(script)],
                              env=env, capture_output=True, text=True)

    def test_provider_build_needs_no_local_public_values_and_cli_still_fails(self):
        result = self.shell('POS_VERCEL_BACKEND=mcp; DEPLOY_MODE=remote; ensure_flutter_env')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('PENDING_PROVIDER_ATTESTATION', result.stdout)
        result = self.shell('POS_VERCEL_BACKEND=cli; ensure_flutter_env')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('SUPABASE_URL is not set', result.stderr)

    def test_missing_cli_config_fails_before_any_full_recipe(self):
        result = self.shell('enforce_clean_git(){ :; }; enforce_origin_main_ancestry(){ :; }; '
                            'enforce_local_release_contract(){ echo RECIPE_MUST_NOT_RUN; }; '
                            'initialize_cloud_execution(){ echo CLOUD_MUST_NOT_START; }; '
                            'preflight')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('RECIPE_MUST_NOT_RUN', result.stdout)

    def test_integrated_owner_waiver_preserves_scope_and_skip_guards(self):
        setup = ('POS_SUPABASE_BACKEND=mcp; POS_VERCEL_BACKEND=mcp; DEPLOY_MODE=remote; '
                 'INTEGRATED_RELEASE_PLAN=scripts/cloud_deployment/plans/20261031_pos_integrated_resilience.json; '
                 'OWNER_VERIFIED_CANDIDATE=/unused; SKIP_LOGIN_SMOKE=1; LOGIN_SMOKE_OPT_OUT=1; ')
        result = self.shell(setup + 'validate_cloud_options')
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.shell(setup + 'SKIP_CHECKS=1; validate_cloud_options')
        self.assertNotEqual(result.returncode, 0)

    def test_same_application_and_explicit_support_changes_only(self):
        before = {'lib/main.dart': 'app', 'scripts/deploy_pos_production.sh': 'old'}
        after = {**before, 'scripts/deploy_pos_production.sh': 'new',
                 'scripts/cloud_deployment/reuse_candidate.py': 'new'}
        self.assertEqual(len(reuse_candidate.changed_support_paths(before, after)), 2)

    def test_application_sql_build_and_recipe_changes_reject_reuse(self):
        for path in ['lib/main.dart', 'supabase/migrations/example.sql',
                     'scripts/vercel_build_web.sh', 'scripts/local_verification/recipe.json']:
            with self.subTest(path=path), self.assertRaises(reuse_candidate.gate.InvalidEvidence):
                reuse_candidate.changed_support_paths({path: 'old'}, {path: 'new'})

    def test_unknown_added_and_removed_inputs_are_not_ignored(self):
        for before, after in [({}, {'unknown': 'new'}), ({'unknown': 'old'}, {})]:
            with self.assertRaises(reuse_candidate.gate.InvalidEvidence):
                reuse_candidate.changed_support_paths(before, after)
