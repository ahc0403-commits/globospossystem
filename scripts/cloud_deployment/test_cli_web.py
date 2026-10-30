import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import cli_web as release


class StagedWebTests(unittest.TestCase):
    def setUp(self):
        self.area = tempfile.TemporaryDirectory(); self.addCleanup(self.area.cleanup)
        self.directory = Path(self.area.name)
        self.manifest = {'sourceSha': 'a' * 40, 'phase': 'integrated'}
        self.previous = {'id': 'dpl_previous', 'readyState': 'READY', 'target': 'production', 'projectId': release.web.PROJECT}
        self.staged = {**self.previous, 'id': 'dpl_staged', 'url': 'fixture.vercel.app',
                       'meta': {'githubCommitSha': self.manifest['sourceSha']}}
        self.build = {'sourceSha': self.manifest['sourceSha'], 'mainDartJsSha256': 'fixture'}
        context = patch.object(release, 'session', return_value=(self.directory, self.manifest))
        context.start(); self.addCleanup(context.stop)

    def test_stage_builds_production_once_and_promote_reuses_identical_bytes(self):
        with patch.object(release.integrated_release, 'bound_plan'), \
             patch.object(release, 'inspect', side_effect=[self.previous, self.staged, self.previous]), \
             patch.object(release.web, 'verify_live', return_value=self.build), \
             patch.object(release.subprocess, 'run') as execute, \
             patch.object(release.subprocess, 'check_output', return_value='https://fixture.vercel.app\n') as deploy:
            release.stage(self.directory)
        self.assertEqual(execute.call_args.args[0], ['vercel', 'build', '--prod'])
        command = deploy.call_args.args[0]
        for flag in ['--prod', '--prebuilt', '--skip-domain']: self.assertIn(flag, command)
        with patch.object(release.integrated_release, 'require_database') as database, \
             patch.object(release, 'inspect', side_effect=[self.staged, self.previous, self.staged]), \
             patch.object(release.web, 'verify_live', return_value=self.build), \
             patch.object(release.subprocess, 'run') as promote:
            release.promote(self.directory)
        database.assert_called_once()
        self.assertEqual(promote.call_args.args[0], ['vercel', 'promote', 'https://fixture.vercel.app', '--yes'])
        receipt = json.loads((self.directory / 'vercel-receipt.json').read_text())
        self.assertEqual(receipt['productionBuildCount'], 1)
        self.assertTrue(receipt['promotedWithoutRebuild'])

    def test_failed_or_missing_db_result_prevents_promotion_command(self):
        with patch.object(release.integrated_release, 'require_database', side_effect=release.CloudError('DB pending')), \
             patch.object(release.subprocess, 'run') as execute, self.assertRaises(release.CloudError):
            release.promote(self.directory)
        execute.assert_not_called()

    def test_inaccessible_staged_build_never_creates_a_verified_stage_receipt(self):
        with patch.object(release.integrated_release, 'bound_plan'), \
             patch.object(release, 'inspect', side_effect=[self.previous, self.staged]), \
             patch.object(release.web, 'verify_live', side_effect=release.CloudError('protected URL')), \
             patch.object(release.subprocess, 'run'), \
             patch.object(release.subprocess, 'check_output', return_value='https://fixture.vercel.app'), \
             self.assertRaises(release.CloudError):
            release.stage(self.directory)
        self.assertFalse((self.directory / 'cli-staged.json').exists())

    def test_concurrent_live_alias_change_prevents_promotion(self):
        (self.directory / 'cli-staged.json').write_text(json.dumps({'sourceSha': self.manifest['sourceSha'],
            'deploymentId': self.staged['id'], 'url': 'https://fixture.vercel.app', 'rollbackDeploymentId': 'dpl_previous'}))
        with patch.object(release.integrated_release, 'require_database'), \
             patch.object(release, 'inspect', side_effect=[self.staged, {**self.previous, 'id': 'dpl_other'}]), \
             patch.object(release.subprocess, 'run') as execute, self.assertRaises(release.CloudError):
            release.promote(self.directory)
        execute.assert_not_called()


if __name__ == '__main__': unittest.main()
