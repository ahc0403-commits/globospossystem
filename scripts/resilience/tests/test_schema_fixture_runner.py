import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import test_schema_snapshot as schema_tests
m=schema_tests.m

spec=importlib.util.spec_from_file_location('schema_runner',Path(__file__).parents[1]/'run_schema_fixture.py')
runner=importlib.util.module_from_spec(spec);spec.loader.exec_module(runner)


class SchemaRunnerTests(unittest.TestCase):
    def setUp(self):
        self.input=schema_tests.SchemaSnapshotTests();self.input.setUp();self.addCleanup(self.input.doCleanups)
        self.area=self.input.area
        self.input.write('pos-inventory-guards.json',{'schemaInventory':sorted(m.SCOPES['pos']),
            **{k:0 for k in ['unsupportedRelations','unsupportedTypes','nonViewRules','customAggregates',
                             'customCollations','schemaPublications','otherLanguages','ordinaryInheritance']}})
        self.output=self.area/'output'

    def execute(self,exit_code=0,foreign=False,cleanup=True,timed_out=False,extra_flags=None,detail_flags=None):
        outer=self
        class Child:
            pid=99999999
            returncode=None
            def __init__(self,command,**kwargs):
                detail={'runId':'another-run' if foreign else kwargs['env']['POS_LOCAL_RUN_ID'],
                        'projectRef':m.PROJECTS['pos'],'semanticCatalogEqual':True}
                detail.update(detail_flags or {})
                suffix='candidate-upgrade' if extra_flags and '--candidate-upgrade' in extra_flags else 'reconstruction'
                outer.input.write('pos-'+suffix+'-report.json',detail)
                self.waits=0
            def wait(self,timeout=None):
                self.waits+=1
                if timed_out and self.waits==1:raise subprocess.TimeoutExpired('owned fixture',600)
                self.returncode=-2 if timed_out else exit_code
                return self.returncode
            def poll(self):return self.returncode
        argv=['schema-runner','pos','--snapshot-dir',str(self.area),'--output',str(self.output)]
        argv.extend(extra_flags or [])
        with patch.object(runner.sys,'argv',argv),patch.object(runner.subprocess,'Popen',Child),\
             patch.object(runner,'cleanup_owned',return_value=cleanup),patch.object(runner.os,'killpg'),\
             contextlib.redirect_stdout(io.StringIO()):
            return runner.main()

    def result(self):return json.loads((self.output/'result.json').read_text())

    def test_success_is_only_development_evidence_with_owned_cleanup(self):
        self.assertEqual(self.execute(),0);x=self.result()
        self.assertEqual(x['status'],'PASS');self.assertTrue(x['cleanupVerified'])
        self.assertFalse(x['officialReleaseReceipt']);self.assertFalse(x['fullPlanComplete'])
        self.assertEqual((self.output/'complete.log').stat().st_mode & 0o777,0o600)

    def test_foreign_run_receipt_is_rejected_and_failure_is_saved(self):
        with self.assertRaisesRegex(ValueError,'another invocation'):self.execute(foreign=True)
        self.assertEqual(self.result()['status'],'FAIL')

    def test_failed_process_or_cleanup_cannot_become_pass(self):
        self.assertEqual(self.execute(exit_code=3),1);self.assertEqual(self.result()['status'],'FAIL')

    def test_cleanup_failure_rejects_otherwise_successful_step(self):
        self.assertEqual(self.execute(cleanup=False),1);self.assertFalse(self.result()['cleanupVerified'])

    def test_timeout_is_not_a_completed_success(self):
        self.assertEqual(self.execute(timed_out=True),1)
        self.assertTrue(self.result()['timedOut']);self.assertEqual(self.result()['status'],'FAIL')

    def test_requested_native_payment_stage_cannot_pass_when_missing(self):
        self.input.write('pos-current-application-schema.sql',{'synthetic-private-test-file':True})
        flags=['--native-roundtrip','--candidate-upgrade','--exercise-existing-transactions','--exercise-payment-receipts']
        detail={'nativeDumpValidated':True,'candidateMigrationSelfChecksPassed':True,
                'existingBusinessRowsPreserved':True,'postUpgradePaymentStockScenarioPassed':True}
        self.assertEqual(self.execute(extra_flags=flags,detail_flags=detail),1)
        self.assertEqual(self.result()['status'],'FAIL')

    def test_payment_stage_without_native_fixture_fails_before_docker(self):
        argv=['schema-runner','pos','--snapshot-dir',str(self.area),'--output',str(self.output),'--exercise-payment-receipts']
        with patch.object(runner.sys,'argv',argv),patch.object(runner.subprocess,'Popen') as child:
            with self.assertRaisesRegex(ValueError,'native POS existing-transaction'):
                runner.main()
            child.assert_not_called()
        self.assertFalse(self.output.exists())

    def test_v1_native_payment_success_does_not_substitute_for_missing_v2(self):
        self.input.write('pos-current-application-schema.sql',{'synthetic-private-test-file':True})
        flags=['--native-roundtrip','--candidate-upgrade','--exercise-existing-transactions','--exercise-payment-receipts']
        detail={'nativeDumpValidated':True,'candidateMigrationSelfChecksPassed':True,
          'existingBusinessRowsPreserved':True,'postUpgradePaymentStockScenarioPassed':True,
          'paymentCommandReceiptScenario':{'count':22,'checksPassed':[str(n) for n in range(22)],
            'nativePaymentFunctionsStubbed':False,
            'fixtureSha256':hashlib.sha256(Path(runner.__file__).with_name('payment_receipt_fixture.py').read_bytes()).hexdigest()}}
        self.assertEqual(self.execute(extra_flags=flags,detail_flags=detail),1)
        self.assertEqual(self.result()['status'],'FAIL')

    def test_native_legal_cannot_mutate_the_retained_financial_fixture(self):
        self.input.write('pos-current-application-schema.sql',{'synthetic-private-test-file':True})
        argv=['schema-runner','pos','--snapshot-dir',str(self.area),'--output',str(self.output),
          '--native-roundtrip','--candidate-upgrade','--exercise-existing-transactions','--exercise-legal-connection']
        with patch.object(runner.sys,'argv',argv),patch.object(runner.subprocess,'Popen') as child:
            with self.assertRaisesRegex(ValueError,'separate from historical'):
                runner.main()
            child.assert_not_called()
        self.assertFalse(self.output.exists())

    def test_owned_diagnostics_are_copied_privately_with_the_original_hash(self):
        source=self.input.write('pos-owned-container-diagnostics.log',{'synthetic':'diagnostics'})
        digest=hashlib.sha256(source.read_bytes()).hexdigest()
        self.assertEqual(self.execute(detail_flags={'ownedContainerDiagnosticSha256':digest}),0)
        target=self.output/'owned-container-diagnostics.log'
        self.assertEqual(target.read_bytes(),source.read_bytes())
        self.assertEqual(target.stat().st_mode & 0o777,0o600)
        self.assertEqual(self.result()['diagnostics']['sha256'],digest)

    def test_changed_diagnostics_cannot_support_a_pass(self):
        self.input.write('pos-owned-container-diagnostics.log',{'synthetic':'changed'})
        with self.assertRaisesRegex(ValueError,'diagnostics changed'):
            self.execute(detail_flags={'ownedContainerDiagnosticSha256':'0'*64})
        self.assertEqual(self.result()['status'],'FAIL')

    def test_cleanup_filters_only_this_run_and_never_prunes(self):
        calls=[];responses=iter(['abc123\n','','','',''])
        def fake(argv,**kwargs):
            calls.append(argv);return subprocess.CompletedProcess(argv,0,next(responses),'')
        with patch.object(runner.subprocess,'run',side_effect=fake):
            self.assertTrue(runner.cleanup_owned('owned-run',{}))
        self.assertTrue(all('--host=unix:///var/run/docker.sock' in c for c in calls))
        self.assertTrue(all('label=pos.local.verification=owned-run' in c for c in calls if '--filter' in c))
        self.assertFalse(any('prune' in c for c in calls))
        self.assertEqual([c for c in calls if 'rm' in c][0][-1],'abc123')


    def test_two_project_fixture_holds_and_releases_both_project_locks(self):
        with runner.fixture_locks(self.area,['pos','office']):
            with self.assertRaises(BlockingIOError):
                with runner.fixture_locks(self.area,['office']):pass
        with runner.fixture_locks(self.area,['office','pos']):pass
        self.assertEqual((self.area/'office-fixture.lock').stat().st_mode & 0o777,0o600)

    def test_fixture_lock_cannot_target_an_unrelated_path(self):
        with self.assertRaisesRegex(ValueError,'explicit fixture projects'):
            with runner.fixture_locks(self.area,['../unrelated']):pass


if __name__=='__main__':unittest.main()
