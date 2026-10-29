import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest

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


if __name__ == '__main__':
    unittest.main()
