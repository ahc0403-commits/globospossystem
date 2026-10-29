import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent))
import migration


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / 'scripts').mkdir()
        self.path = self.root / '20261028053422_example.sql'
        self.original = '-- production-gate: self-verifying\nBEGIN;\nCREATE TABLE fixture(id integer);\nCOMMIT;\n'
        self.path.write_text(self.original)

    def test_original_version_and_bytes_are_bound_to_one_atomic_statement(self):
        prepared = migration.prepare(self.path, 'a' * 40, self.root)
        self.assertEqual(prepared['version'], '20261028053422')
        self.assertEqual(prepared['sourceHash'], migration.digest(self.original))
        self.assertTrue(prepared['query'].startswith('DO $pos_cloud_atomic_migration$'))
        self.assertIn('pg_advisory_xact_lock', prepared['query'])
        self.assertIn('POS_MIGRATION_ALREADY_APPLIED', prepared['query'])
        self.assertIn('POS_PSQL_ROLE_ACTIVATION_FAILED', prepared['query'])
        self.assertIn('POS_MIGRATION_SOURCE_HISTORY_MISMATCH', prepared['query'])
        self.assertIn(migration.literal(self.original), prepared['query'])
        self.assertEqual(migration.sql_body(self.original).strip(), 'CREATE TABLE fixture(id integer);')

    def test_companion_checks_are_required_and_hashed_in_order(self):
        self.path.write_text('BEGIN; CREATE TABLE fixture(id integer); COMMIT;')
        with self.assertRaises(migration.CloudError):
            migration.prepare(self.path, 'a' * 40, self.root)
        (self.root / 'scripts/preflight_example.sql').write_text('SELECT 1;')
        (self.root / 'scripts/verify_example.sql').write_text('SELECT 2;')
        prepared = migration.prepare(self.path, 'a' * 40, self.root)
        self.assertEqual(len(prepared['inputHashes']), 3)
        self.assertLess(prepared['query'].find('SELECT 1;'), prepared['query'].find('CREATE TABLE'))
        self.assertLess(prepared['query'].find('CREATE TABLE'), prepared['query'].find('SELECT 2;'))

    def test_unknown_psql_directives_and_unmatched_transactions_stop(self):
        for text in ['\\ir outside.sql', 'BEGIN; SELECT 1;', '\\set password private']:
            with self.subTest(text=text), self.assertRaises(migration.CloudError):
                migration.sql_body(text)

    def test_sql_outside_source_is_not_loaded(self):
        with self.assertRaises(migration.CloudError):
            migration.source_file('/etc/hosts', self.root)

    def test_reuse_requires_original_and_transport_statement_hashes_and_metadata(self):
        p = migration.prepare(self.path, 'a' * 40, self.root)
        versions = [{'version': p['version'], 'name': p['slug']},
                    {'version': '20261029112749', 'name': p['transportName']}]
        original = {'version': p['version'], 'name': p['slug'], 'source_hash': p['sourceHash'],
                    'source_metadata': p['metadata'], 'statement_count': 2}
        transport = {'version': '20261029112749', 'name': p['transportName'],
                     'source_hash': p['queryHash'], 'source_metadata': None, 'statement_count': 1}
        with patch.object(migration, 'request', return_value={'rows': [original, transport]}):
            self.assertTrue(migration.verify_applied('/fixture', p, versions)['historyVerified'])
        for rows in [[{**original, 'source_hash': 'wrong'}, transport],
                     [{**original, 'source_metadata': 'another release'}, transport],
                     [original, {**transport, 'source_hash': 'another SQL statement'}],
                     [original], [original, transport, transport]]:
            with self.subTest(rows=rows), patch.object(migration, 'request', return_value={'rows': rows}), \
                 self.assertRaises(migration.CloudError):
                migration.verify_applied('/fixture', p, versions)

    def test_original_order_query_remains_identical_to_expired_approved_intent(self):
        p = migration.prepare(migration.ROOT / 'supabase/migrations/20261029081324_direct_order_amendments.sql',
                              '5e6b7452ef348dfd466e9570a918f3ac70ea28db')
        self.assertEqual(p['sourceHash'], '9533ad9491ce65baa3fbfea8c74c8a4a5a4dd9719e998fff27ae4909616743a5')
        self.assertEqual(p['queryHash'], '2b60c9139e8569e9e695683eec63e4966f531a73ef2be8f278b2b542c66197c6')


if __name__ == '__main__':
    unittest.main()
