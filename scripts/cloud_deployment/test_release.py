import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import release


class CoordinatedReleaseTests(unittest.TestCase):
    def setUp(self):
        self.path = release.ROOT / 'scripts/cloud_deployment/plans/20261029_attendance_orders.json'
        _, self.plan = release.load_plan(self.path)
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.manifest = {'sourceSha': 'a' * 40, 'phase': 'coordinated'}

    def test_only_exact_migration_queries_and_edge_payload_are_authorized(self):
        with patch.object(release, 'bound_plan', return_value=self.plan):
            for row in self.plan['migrations']:
                p = release.migration.prepare(release.ROOT / row['path'], self.plan['migrationSourceSha'])
                good = {'name': p['transportName'], 'query': p['query']}
                release.authorize_mutation(self.directory, self.manifest, 'apply', good)
                for changed in [{**good, 'query': good['query'] + 'SELECT 1;'},
                                {**good, 'name': 'arbitrary'}]:
                    with self.assertRaises(release.CloudError):
                        release.authorize_mutation(self.directory, self.manifest, 'apply', changed)
            good = release.payload(self.plan)
            release.authorize_mutation(self.directory, self.manifest, 'deploy-function', good)
            for changed in [{**good, 'name': 'other-handler'}, {**good, 'verify_jwt': True},
                            {**good, 'files': []}]:
                with self.assertRaises(release.CloudError):
                    release.authorize_mutation(self.directory, self.manifest, 'deploy-function', changed)

    def run_release(self, fail_version=None, drift=False, applied_count=0, bad_history=False, out_of_order=False):
        before = {'slug': release.EDGE, 'version': 59, 'verify_jwt': False,
                  'files': [{'name': 'direct-order-public/index.ts',
                             'content': (release.ROOT / release.FILES[0]).read_text()}]}
        after = {**before, 'version': 60}
        events = []
        def apply_migration(directory, path, source_sha=None):
            self.assertEqual(source_sha, self.plan['migrationSourceSha'])
            events.append(Path(path).name)
            if fail_version and Path(path).name.startswith(fail_version):
                raise release.CloudError('fixture migration failure')
        def request(directory, operation, args):
            events.append(operation)
            applied = release.MIGRATIONS[1:2] if out_of_order else release.MIGRATIONS[:applied_count]
            return {'migrations': [{'version': Path(p).name.split('_')[0]} for p in applied]} if operation == 'migrations' else {'success': True}
        def verify(directory, prepared, versions):
            if bad_history:
                raise release.CloudError('persisted hash changed')
            return {'version': prepared['version'], 'historyVerified': True}
        with patch.object(release, 'session', return_value=(self.directory, self.manifest)), \
             patch.object(release, 'bound_plan', return_value=self.plan), \
             patch.object(release, 'edge_state', side_effect=[before, {**before, 'version': 61} if drift else before, after]), \
             patch.object(release, 'request', side_effect=request), \
             patch.object(release.migration, 'apply', side_effect=apply_migration), \
             patch.object(release.migration, 'verify_applied', side_effect=verify):
            try:
                release.apply(self.directory, self.path)
            except release.CloudError:
                return events, False
        return events, True

    def test_ordered_three_migrations_before_one_edge_and_web_stays_pending(self):
        events, ok = self.run_release()
        self.assertTrue(ok)
        self.assertEqual(events, ['migrations', *[Path(p).name for p in release.MIGRATIONS], 'deploy-function'])
        result = json.loads((self.directory / 'coordinated-result.json').read_text())
        self.assertEqual(result['web'], 'PENDING')
        self.assertFalse(result['edge']['importMapReturnedAndCompared'])

    def test_any_migration_failure_or_concurrent_edge_change_blocks_deploy(self):
        events, ok = self.run_release(fail_version='20261029081324')
        self.assertFalse(ok)
        self.assertNotIn('deploy-function', events)
        (self.directory / 'edge-before.json').unlink()
        events, ok = self.run_release(drift=True)
        self.assertFalse(ok)
        self.assertNotIn('deploy-function', events)

    def test_metadata_jwt_source_mismatch_blocks(self):
        for change in [{'verify_jwt': True}, {'status': 'ERROR'}, {'slug': 'wrong'}]:
            remote = {'slug': release.EDGE, 'version': 59, 'status': 'ACTIVE', 'verify_jwt': False, **change}
            with patch.object(release, 'request', return_value={'functions': [remote]}), \
                 self.assertRaises(release.CloudError):
                release.edge_state(self.directory, '0' * 64)

    def test_verified_applied_prefix_is_never_reexecuted(self):
        events, ok = self.run_release(applied_count=1)
        self.assertTrue(ok)
        self.assertNotIn(Path(release.MIGRATIONS[0]).name, events)
        self.assertEqual(events[1:3], [Path(p).name for p in release.MIGRATIONS[1:]])
        result = json.loads((self.directory / 'coordinated-result.json').read_text())
        self.assertEqual(result['migrationResults'][0]['status'], 'ALREADY_APPLIED_VERIFIED_NOT_REEXECUTED')

    def test_bad_existing_history_stops_before_any_new_apply(self):
        events, ok = self.run_release(applied_count=1, bad_history=True)
        self.assertFalse(ok)
        self.assertEqual(events, ['migrations'])

    def test_existing_nonprefix_version_stops_before_any_new_apply(self):
        events, ok = self.run_release(out_of_order=True)
        self.assertFalse(ok)
        self.assertEqual(events, ['migrations'])


if __name__ == '__main__':
    unittest.main()
