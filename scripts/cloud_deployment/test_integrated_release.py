import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import integrated_release as release
import vercel_release as web


class IntegratedReleaseTests(unittest.TestCase):
    def setUp(self):
        self.area = tempfile.TemporaryDirectory()
        self.addCleanup(self.area.cleanup)
        self.directory = Path(self.area.name)
        self.path = release.ROOT / 'scripts/cloud_deployment/plans/20261030_integrated_pos.json'
        _, self.plan = release.load_plan(self.path)
        self.manifest = {'sourceSha': 'a' * 40, 'phase': 'integrated'}
        self.context = patch.object(release, 'session', return_value=(self.directory, self.manifest))
        self.context.start(); self.addCleanup(self.context.stop)
        self.bound = patch.object(release, 'bound_plan', return_value=self.plan)
        self.bound.start(); self.addCleanup(self.bound.stop)

    def test_plan_rejects_reorder_hash_drift_destructive_scope_and_sql_probe_injection(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            folder = root / 'scripts/cloud_deployment/plans'; folder.mkdir(parents=True)
            (root / 'supabase/migrations').mkdir(parents=True)
            for row in self.plan['migrations']:
                (root / row['path']).write_bytes((release.ROOT / row['path']).read_bytes())
                slug = Path(row['path']).stem.split('_', 1)[1]
                for prefix in ['preflight', 'apply', 'verify']:
                    companion = Path('scripts') / (prefix + '_' + slug + '.sql')
                    if (release.ROOT / companion).exists():
                        (root / companion).write_bytes((release.ROOT / companion).read_bytes())
            path = folder / 'fixture.json'
            changes = [lambda p: p['migrations'].reverse(),
                       lambda p: p['migrations'].append(p['migrations'][0]),
                       lambda p: p['migrations'][0].update(sha256='0' * 64),
                       lambda p: p.update(backwardCompatible=False),
                       lambda p: p.update(edge={'name': 'unexpected'}),
                       lambda p: p['contracts'][0].update(signature="public.f(uuid); DELETE FROM users;")]
            for change in changes:
                plan = copy.deepcopy(self.plan); change(plan); path.write_text(json.dumps(plan))
                # The fixture tree has no companions. Preserve the real prepare
                # contract while reading these identical self-contained fixtures.
                with self.subTest(change=change), self.assertRaises(release.CloudError):
                    release.load_plan(path, root)

    def test_return_type_mismatch_stops_read_only_preflight_before_any_apply(self):
        wrong = {'rows': [{'signature': 'public.user_accessible_stores(uuid)',
                           'result_type': 'TABLE(store_id uuid)'}]}
        with patch.object(release, 'request', return_value=wrong) as remote, \
             patch.object(release.migration, 'apply') as apply, self.assertRaises(release.CloudError):
            release.preflight(self.directory)
        self.assertEqual([c.args[1] for c in remote.call_args_list], ['query'])
        apply.assert_not_called()
        self.assertFalse((self.directory / 'integrated-preflight.json').exists())

    def test_ordered_atomic_migrations_complete_before_web_authorization(self):
        events = []
        (self.directory / 'integrated-preflight.json').write_text('{}')
        with patch.object(release, 'verify_contracts'), \
             patch.object(release, 'request', return_value={'migrations': []}), \
             patch.object(release.migration, 'apply', side_effect=lambda directory, path:
                 events.append(Path(path).name) or {'historyVerified': True}):
            release.apply(self.directory)
        self.assertEqual(events, [Path(row['path']).name for row in self.plan['migrations']])
        release.require_database(self.directory, self.manifest)
        with patch.object(web, 'deployment_arguments', return_value={'fixture': True}):
            (self.directory / 'vercel-prepared.json').write_text(json.dumps(
                {'sourceSha': self.manifest['sourceSha'], 'arguments': {'fixture': True}}))
            web.authorize_mutation(self.directory, self.manifest, {'fixture': True})

    def test_middle_failure_blocks_later_migrations_and_web(self):
        (self.directory / 'integrated-preflight.json').write_text('{}')
        with patch.object(release, 'verify_contracts'), \
             patch.object(release, 'request', return_value={'migrations': []}), \
             patch.object(release.migration, 'apply', side_effect=[{'historyVerified': True}, release.CloudError('fixture failure')]) as apply, \
             self.assertRaises(release.CloudError):
            release.apply(self.directory)
        self.assertEqual(apply.call_count, 2)
        self.assertFalse((self.directory / 'integrated-db-result.json').exists())
        with self.assertRaises(OSError): release.require_database(self.directory, self.manifest)

    def test_applied_nonprefix_is_rejected_before_any_write(self):
        version = Path(self.plan['migrations'][1]['path']).name.split('_')[0]
        with patch.object(release, 'request', return_value={'migrations': [{'version': version}]}), \
             self.assertRaises(release.CloudError):
            release.database_state(self.directory, self.manifest, self.plan)

    def test_previously_applied_sql_preserves_original_source_and_checks_hashes(self):
        row = self.plan['migrations'][0]
        plan = {**self.plan, 'migrations': [row]}
        prepared = release.migration.prepare(release.ROOT / row['path'], 'b' * 40)
        metadata = '-- POS_CLOUD_SOURCE ' + release.canonical({'sourceSha': 'b' * 40, 'inputHashes': prepared['inputHashes']})
        with patch.object(release, 'request', side_effect=[{'migrations': [{'version': prepared['version']}]},
                    {'rows': [{'metadata': metadata}]}]), \
             patch.object(release.subprocess, 'run') as ancestor, \
             patch.object(release.migration, 'verify_applied', return_value={'historyVerified': True}) as verify:
            ancestor.return_value.returncode = 0
            result = release.database_state(self.directory, self.manifest, plan)
        self.assertEqual(result[0]['status'], 'ALREADY_APPLIED_VERIFIED_NOT_REEXECUTED')
        self.assertEqual(verify.call_args.args[1]['metadata'], prepared['metadata'])
        changed = metadata.replace('b' * 40, 'not-a-sha')
        with patch.object(release, 'request', side_effect=[{'migrations': [{'version': prepared['version']}]},
                    {'rows': [{'metadata': changed}]}]), self.assertRaises(release.CloudError):
            release.database_state(self.directory, self.manifest, plan)

    def test_mutation_binding_rejects_unplanned_sql_and_any_edge_write(self):
        (self.directory / 'integrated-apply-started.json').write_text('{}')
        prepared = release.migration.prepare(release.ROOT / self.plan['migrations'][0]['path'], self.manifest['sourceSha'])
        good = {'name': prepared['transportName'], 'query': prepared['query']}
        release.authorize_mutation(self.directory, self.manifest, 'apply', good)
        for operation, arguments in [('apply', {**good, 'query': good['query'] + 'SELECT 1;'}),
                                     ('deploy-function', {'name': 'direct-order-public'})]:
            with self.assertRaises(release.CloudError):
                release.authorize_mutation(self.directory, self.manifest, operation, arguments)


if __name__ == '__main__': unittest.main()
