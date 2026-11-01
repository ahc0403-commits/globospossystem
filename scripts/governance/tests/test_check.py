import copy
import json
import subprocess
import sys
from pathlib import Path
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import check


class ChangeGovernanceTests(unittest.TestCase):
    def setUp(self):
        self.area = tempfile.TemporaryDirectory()
        self.addCleanup(self.area.cleanup)
        self.root = Path(self.area.name)
        self.put('lib/features/payment/page.dart', "import '../../core/shared.dart';\n")
        self.put('lib/features/qc/page.dart', "import '../../core/shared.dart';\n")
        self.put('lib/core/shared.dart', 'const value = 1;\n')
        self.put('test/payment_test.dart', 'fixture\n')
        self.put('test/qc_test.dart', 'fixture\n')
        self.put('scripts/local_verification/recipe.json', '{}\n')
        self.put('scripts/governance/tests/test_check.py', '# fixture test source\n')
        self.run_git('init', '-q')
        self.run_git('config', 'user.email', 'fixture@example.test')
        self.run_git('config', 'user.name', 'Governance fixture')
        self.run_git('add', '.')
        self.run_git('commit', '-qm', 'base fixture')
        self.base = self.run_git('rev-parse', 'HEAD').strip()
        self.registry = {
            'schemaVersion': 1, 'dartPackage': 'fixture',
            'features': [{'id': name, 'owner': name, 'checks': [name], 'adoption': 'legacy_or_partial'}
                         for name in ['payment', 'qc']],
            'checks': {'payment': {'path': 'test/payment_test.dart'},
                       'qc': {'path': 'test/qc_test.dart'},
                       'official-full-recipe': {'path': 'scripts/local_verification/recipe.json'},
                       'governance-unit': {'path': 'scripts/governance/tests/test_check.py'}},
            'sharedAreas': [{'id': 'database', 'paths': ['supabase/*'], 'affectsAllFeatures': True}],
            'workstreams': [{'id': 'G' + str(i), 'status': 'open', 'requiredEvidence': ['real_execution']}
                            for i in range(8)],
        }
        self.change = {
            'schemaVersion': 1, 'baseSha': self.base, 'kind': 'application',
            'summary': 'Payment fixture change', 'inputs': {},
            'affectedFeatures': ['payment', 'qc'], 'sharedAreas': [],
            'requiredChecks': ['official-full-recipe', 'governance-unit'],
            'businessInvariants': ['Money and tenant access remain correct'],
            'rollback': 'Revert source; preserve committed financial records.',
            'risk': {k: k == 'business' for k in check.RISK_FLAGS},
            'dataAccessReview': {k: {'applicable': False, 'reason': 'Reviewed against bounded fixture behavior.'}
                                 for k in check.DIMENSIONS},
            'contractReview': {k: {'applicable': False, 'reason': 'Reviewed against preserved domain fixture contracts.'}
                               for k in check.CONTRACTS},
            'claims': {'allPlanComplete': False, 'performanceImproved': False},
        }

    def run_git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.root, stderr=subprocess.PIPE).decode()

    def put(self, path, body):
        p = self.root / path
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(body)

    def prepare(self, change=None):
        self.put(check.REGISTRY, json.dumps(self.registry))
        current = copy.deepcopy(change or self.change)
        self.put(check.CHANGE, json.dumps(current))
        current['inputs'] = check.changed_inputs(self.root, self.base)
        self.put(check.CHANGE, json.dumps(current))
        return current

    def test_reviewed_feature_change_passes_without_running_product_tests(self):
        self.put('lib/features/payment/page.dart', 'const changed = 2;\n')
        self.prepare()
        value = check.validate(self.root)
        self.assertEqual(value['status'], 'PASS')
        self.assertFalse(value['productCompletion'])

    def test_new_feature_cannot_silently_escape_inventory(self):
        self.put('lib/features/attendance/page.dart', 'const x = 1;\n')
        self.prepare()
        with self.assertRaisesRegex(check.GovernanceError, 'inventory mismatch'):
            check.validate(self.root)

    def test_missing_verification_source_is_rejected(self):
        self.registry['checks']['payment']['path'] = 'test/does_not_exist.dart'
        self.prepare()
        with self.assertRaisesRegex(check.GovernanceError, 'Missing verification source'):
            check.validate(self.root)

    def test_shared_import_transitive_consumers_must_be_declared(self):
        self.put('lib/core/shared.dart', 'const changed = 2;\n')
        change = {**self.change, 'affectedFeatures': ['payment']}
        self.prepare(change)
        with self.assertRaisesRegex(check.GovernanceError, 'Missing affected features.*qc'):
            check.validate(self.root)

    def test_deleted_shared_module_keeps_base_consumers_in_impact(self):
        (self.root / 'lib/core/shared.dart').unlink()
        self.put('lib/features/qc/page.dart', 'const replacement = 2;\n')
        self.prepare({**self.change, 'affectedFeatures': ['qc']})
        with self.assertRaisesRegex(check.GovernanceError, 'Missing affected features.*payment'):
            check.validate(self.root)

    def test_unrecorded_edit_or_new_file_invalidates_input_hashes(self):
        self.prepare()
        self.put('lib/features/payment/new.dart', 'const unnoticed = 1;\n')
        with self.assertRaisesRegex(check.GovernanceError, 'inputs are missing or stale'):
            check.validate(self.root)

    def test_executable_mode_is_bound_to_declared_input(self):
        self.put('scripts/check.sh', '#!/bin/sh\nexit 0\n')
        self.prepare()
        (self.root / 'scripts/check.sh').chmod(0o755)
        with self.assertRaisesRegex(check.GovernanceError, 'inputs are missing or stale'):
            check.validate(self.root)

    def test_product_source_cannot_use_tooling_exemption(self):
        self.put('lib/features/payment/page.dart', 'const changed = 1;\n')
        self.prepare({**self.change, 'kind': 'tooling'})
        with self.assertRaisesRegex(check.GovernanceError, 'classified as tooling'):
            check.validate(self.root)

    def test_application_changes_require_official_recipe(self):
        self.put('lib/features/payment/page.dart', 'const changed = 1;\n')
        self.prepare({**self.change, 'requiredChecks': ['payment']})
        with self.assertRaisesRegex(check.GovernanceError, 'official full recipe'):
            check.validate(self.root)

    def test_sql_change_requires_all_feature_scope_and_db_review(self):
        self.put('supabase/migrations/change.sql', 'SELECT 1;\n')
        self.prepare({**self.change, 'sharedAreas': ['database']})
        with self.assertRaisesRegex(check.GovernanceError, 'DB-contract review'):
            check.validate(self.root)

    def test_every_performance_dimension_needs_review(self):
        change = copy.deepcopy(self.change)
        del change['dataAccessReview']['retryIdempotency']
        self.prepare(change)
        with self.assertRaisesRegex(check.GovernanceError, 'eleven'):
            check.validate(self.root)

    def test_scope_and_business_contracts_cannot_be_omitted(self):
        change = copy.deepcopy(self.change)
        del change['contractReview']['tenantScope']
        self.prepare(change)
        with self.assertRaisesRegex(check.GovernanceError, 'review is incomplete'):
            check.validate(self.root)

    def test_applicable_business_contract_needs_selected_check(self):
        change = copy.deepcopy(self.change)
        change['contractReview']['outcomes'].update(applicable=True, checks=['unknown-check'])
        self.prepare(change)
        with self.assertRaisesRegex(check.GovernanceError, 'must reference selected checks'):
            check.validate(self.root)

    def test_relevant_performance_risk_needs_scale_and_verification(self):
        change = copy.deepcopy(self.change)
        change['dataAccessReview']['nPlusOne']['applicable'] = True
        self.prepare(change)
        with self.assertRaisesRegex(check.GovernanceError, 'scale and verification'):
            check.validate(self.root)

    def test_checkbox_cannot_promote_unverified_work_to_operational(self):
        self.registry['workstreams'][2]['status'] = 'operationally_verified'
        self.prepare()
        with self.assertRaisesRegex(check.GovernanceError, 'external evidence'):
            check.validate(self.root)

    def test_declared_measurement_and_whole_plan_pass_are_not_evidence(self):
        for key in ['allPlanComplete', 'performanceImproved']:
            change = copy.deepcopy(self.change)
            change['claims'][key] = True
            self.prepare(change)
            with self.subTest(key=key), self.assertRaisesRegex(check.GovernanceError, 'cannot assert'):
                check.validate(self.root)

    def test_no_unrelated_full_flutter_run_for_tooling_change(self):
        self.put('scripts/governance/check.py', '# reviewed tooling\n')
        change = {**self.change, 'kind': 'tooling', 'affectedFeatures': [],
                  'requiredChecks': ['governance-unit']}
        self.prepare(change)
        self.assertEqual(check.validate(self.root)['kind'], 'tooling')

    def test_path_escape_and_wrong_base_are_rejected(self):
        for name in ['../outside', '/outside', 'test/../outside', 'test\\outside']:
            with self.subTest(name=name), self.assertRaises(check.GovernanceError):
                check.repository_file(self.root, name)
        with self.assertRaises(check.GovernanceError):
            check.changed_inputs(self.root, 'not-a-sha')


if __name__ == '__main__':
    unittest.main()
