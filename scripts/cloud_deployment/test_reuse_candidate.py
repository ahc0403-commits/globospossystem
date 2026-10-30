import unittest
import reuse_candidate


class ReuseCandidateTests(unittest.TestCase):
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
