#!/usr/bin/env python3
"""Real local PostgreSQL tests for read-only catalog drift detection.

Uses an explicitly named disposable Docker fixture, never a database URL.
The fixture must have supabase_migrations.schema_migrations; production
connections and business objects are not used. Each mutation is rolled back.
"""
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import unittest

SPEC = importlib.util.spec_from_file_location('runtime_catalog', Path(__file__).with_name('runtime_catalog.py'))
m = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(m)
QUERY = Path(__file__).with_name('runtime_contracts.sql').read_text()


class CatalogIntegration(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.container = os.environ.get('POS_CATALOG_TEST_CONTAINER', '')
        if not re.fullmatch(r'pos-resilience-catalog-[a-z0-9-]+', cls.container):
            raise RuntimeError('Explicit disposable pos-resilience-catalog-* fixture required')

    def sql(self, text):
        result = subprocess.run(['docker', 'exec', '-i', self.container, 'psql', '-X',
            '-U', 'postgres', '-v', 'ON_ERROR_STOP=1', '-Atq'], input=text, text=True,
            capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def changed(self, mutation):
        # All objects exist only in one local transaction, independent of other tests.
        setup = """
        BEGIN;
        SET LOCAL statement_timeout='10s';
        CREATE SCHEMA resilience_catalog_fixture;
        CREATE SEQUENCE resilience_catalog_fixture.int64_boundary AS bigint;
        CREATE TABLE resilience_catalog_fixture.entries(id int, actor text DEFAULT 'private-default-sentinel');
        CREATE INDEX entries_actor ON resilience_catalog_fixture.entries(actor);
        ALTER TABLE resilience_catalog_fixture.entries ENABLE ROW LEVEL SECURITY;
        CREATE POLICY actor_scope ON resilience_catalog_fixture.entries USING(actor=current_user);
        CREATE FUNCTION resilience_catalog_fixture.lookup(v int) RETURNS int LANGUAGE sql
          AS $$SELECT v+1 /* private-function-sentinel */$$;
        CREATE FUNCTION resilience_catalog_fixture.on_write() RETURNS trigger LANGUAGE plpgsql
          AS $$BEGIN RETURN NEW; END$$;
        CREATE TRIGGER on_write BEFORE INSERT ON resilience_catalog_fixture.entries
          FOR EACH ROW EXECUTE FUNCTION resilience_catalog_fixture.on_write();
        INSERT INTO supabase_migrations.schema_migrations(version,name,statements)
          VALUES ('99999999999999','catalog_fixture',ARRAY['private-history-sentinel']);
        """
        raw = self.sql(setup + QUERY + '\n' + mutation + '\n' + QUERY + '\nROLLBACK;')
        rows = [json.loads(line) for line in raw.splitlines() if line.startswith('{')]
        self.assertEqual(len(rows), 2)
        for snapshot in rows: m.validate(snapshot)
        def record(s):
            return {'projectRef': 'local-fixture', 'snapshot': s, 'catalogSha256': m.catalog_hash(s)}
        return m.compare(record(rows[0]), record(rows[1])), raw

    def test_definitions_are_hashed_and_business_contents_absent(self):
        diff, raw = self.changed("INSERT INTO resilience_catalog_fixture.entries VALUES(1,'private-business-sentinel');")
        self.assertEqual(diff['changed'], [])
        self.assertEqual(diff['added'], [])
        for secret in ('private-default-sentinel', 'private-function-sentinel',
                       'private-history-sentinel', 'private-business-sentinel'):
            self.assertNotIn(secret, raw)

    def test_int64_sequence_boundaries_survive_json_transports(self):
        _, raw = self.changed('SELECT 1;')
        data = next(json.loads(line) for line in raw.splitlines() if line.startswith('{'))
        sequence = next(r for r in data['objects'] if r['kind'] == 'sequence'
                        and r['identity'] == 'resilience_catalog_fixture.int64_boundary')
        self.assertEqual(sequence['detail']['max'], '9223372036854775807')
        self.assertIsInstance(sequence['detail']['start'], str)

    def test_function_definition_security_and_grants_detected(self):
        diff, _ = self.changed("""CREATE OR REPLACE FUNCTION resilience_catalog_fixture.lookup(v int)
          RETURNS int LANGUAGE sql SECURITY DEFINER SET search_path=pg_catalog AS $$SELECT v+2$$;
          REVOKE ALL ON FUNCTION resilience_catalog_fixture.lookup(int) FROM PUBLIC;""")
        self.assertIn(['routine', 'resilience_catalog_fixture.lookup(v integer)'], diff['changed'])

    def test_policy_and_rls_drift_detected(self):
        diff, _ = self.changed("""ALTER POLICY actor_scope ON resilience_catalog_fixture.entries USING(true);
          ALTER TABLE resilience_catalog_fixture.entries DISABLE ROW LEVEL SECURITY;""")
        self.assertIn(['policy', 'resilience_catalog_fixture.entries.actor_scope'], diff['changed'])
        self.assertIn(['relation', 'resilience_catalog_fixture.entries'], diff['changed'])

    def test_trigger_disable_detected(self):
        diff, _ = self.changed('ALTER TABLE resilience_catalog_fixture.entries DISABLE TRIGGER on_write;')
        self.assertIn(['trigger', 'resilience_catalog_fixture.entries.on_write'], diff['changed'])

    def test_index_removal_and_column_default_detected(self):
        diff, _ = self.changed("""DROP INDEX resilience_catalog_fixture.entries_actor;
          ALTER TABLE resilience_catalog_fixture.entries ALTER COLUMN actor SET DEFAULT 'changed';""")
        self.assertIn(['index', 'resilience_catalog_fixture.entries_actor'], diff['removed'])
        self.assertIn(['relation', 'resilience_catalog_fixture.entries'], diff['changed'])

    def test_history_statement_change_detected(self):
        diff, _ = self.changed("UPDATE supabase_migrations.schema_migrations SET statements=ARRAY['changed'] WHERE version='99999999999999';")
        self.assertIn(['migration', '99999999999999'], diff['changed'])


if __name__ == '__main__':
    unittest.main()
