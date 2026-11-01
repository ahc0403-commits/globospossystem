import contextlib
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

    def execute(self,exit_code=0,foreign=False,cleanup=True,timed_out=False):
        outer=self
        class Child:
            pid=99999999
            returncode=None
            def __init__(self,command,**kwargs):
                detail={'runId':'another-run' if foreign else kwargs['env']['POS_LOCAL_RUN_ID'],
                        'projectRef':m.PROJECTS['pos'],'semanticCatalogEqual':True}
                outer.input.write('pos-reconstruction-report.json',detail)
                self.waits=0
            def wait(self,timeout=None):
                self.waits+=1
                if timed_out and self.waits==1:raise subprocess.TimeoutExpired('owned fixture',600)
                self.returncode=-2 if timed_out else exit_code
                return self.returncode
            def poll(self):return self.returncode
        argv=['schema-runner','pos','--snapshot-dir',str(self.area),'--output',str(self.output)]
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


if __name__=='__main__':unittest.main()
