#!/usr/bin/env python3
"""Real PostgreSQL atomicity/history tests in a disposable local-only cluster."""
import concurrent.futures
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import migration


class AtomicMigrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.area = tempfile.TemporaryDirectory(prefix='pos-cloud-sql-fixture-')
        cls.base = Path(cls.area.name)
        cls.data = cls.base / 'postgres'
        cls.bin = Path(subprocess.check_output(['pg_config', '--bindir'], text=True).strip())
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0)); cls.port = sock.getsockname()[1]
        subprocess.run([str(cls.bin/'initdb'), '-D', str(cls.data), '-U', 'postgres', '--auth=trust', '--no-locale'],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run([str(cls.bin/'pg_ctl'), '-D', str(cls.data), '-l', str(cls.base/'postgres.log'),
                        '-o', f'-h 127.0.0.1 -p {cls.port} -k {cls.base}', '-w', 'start'],
                       check=True, stdout=subprocess.DEVNULL)

    @classmethod
    def tearDownClass(cls):
        subprocess.run([str(cls.bin/'pg_ctl'), '-D', str(cls.data), '-m', 'immediate', '-w', 'stop'],
                       check=True, stdout=subprocess.DEVNULL)
        cls.area.cleanup()

    def sql(self, text, check=True):
        result = subprocess.run([str(self.bin/'psql'), '-X', '-h', '127.0.0.1', '-p', str(self.port),
                                 '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1', '-Atq'],
                                input=text, text=True, capture_output=True)
        if check and result.returncode:
            raise AssertionError(result.stderr)
        return result

    def setUp(self):
        self.sql('DROP TABLE IF EXISTS public.cloud_fixture; DROP SCHEMA IF EXISTS supabase_migrations CASCADE; '
                 'CREATE SCHEMA supabase_migrations; CREATE TABLE supabase_migrations.schema_migrations('
                 'version text PRIMARY KEY,name text,statements text[]);')
        self.source = self.base / 'source'
        shutil.rmtree(self.source, ignore_errors=True)
        (self.source/'scripts').mkdir(parents=True)
        self.path = self.source/'20261028053422_fixture.sql'

    def prepare(self, body, verify=None):
        original = '-- production-gate: self-verifying\nBEGIN;\n' + body + '\nCOMMIT;\n'
        self.path.write_text(original)
        if verify is not None:
            (self.source/'scripts/verify_fixture.sql').write_text(verify)
        return migration.prepare(self.path, 'a'*40, self.source)

    def test_success_preserves_exact_source_bytes_and_original_version(self):
        prepared = self.prepare("CREATE TABLE public.cloud_fixture(value text); "
                                "INSERT INTO public.cloud_fixture VALUES ('Văn bản / 원본');")
        self.sql(prepared['query'])
        self.assertEqual(self.sql('SELECT count(*) FROM public.cloud_fixture').stdout.strip(), '1')
        actual = self.sql("SELECT encode(sha256(convert_to(statements[1],'UTF8')),'hex') "
                          "FROM supabase_migrations.schema_migrations WHERE version='20261028053422'").stdout.strip()
        self.assertEqual(actual, prepared['sourceHash'])

    def test_ddl_and_history_both_roll_back_on_migration_error(self):
        prepared = self.prepare("CREATE TABLE public.cloud_fixture(value text); "
                                "DO $$ BEGIN RAISE EXCEPTION 'EXPECTED_FIXTURE_FAILURE'; END $$;")
        failed = self.sql(prepared['query'], check=False)
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn('EXPECTED_FIXTURE_FAILURE', failed.stderr)
        self.assertEqual(self.sql("SELECT to_regclass('public.cloud_fixture') IS NULL").stdout.strip(), 't')
        self.assertEqual(self.sql('SELECT count(*) FROM supabase_migrations.schema_migrations').stdout.strip(), '0')

    def test_postcondition_failure_rolls_back_all_effects(self):
        prepared = self.prepare('CREATE TABLE public.cloud_fixture(value text);',
                                "DO $$ BEGIN RAISE EXCEPTION 'POSTCONDITION_FAILED'; END $$;")
        failed = self.sql(prepared['query'], check=False)
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn('POSTCONDITION_FAILED', failed.stderr)
        self.assertEqual(self.sql("SELECT to_regclass('public.cloud_fixture') IS NULL").stdout.strip(), 't')
        self.assertEqual(self.sql('SELECT count(*) FROM supabase_migrations.schema_migrations').stdout.strip(), '0')

    def test_concurrent_identical_apply_has_one_effect_and_one_history_row(self):
        prepared = self.prepare('CREATE TABLE public.cloud_fixture(value text);')
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: self.sql(prepared['query'], check=False), range(2)))
        self.assertEqual(sum(result.returncode == 0 for result in results), 1)
        self.assertTrue(any('POS_MIGRATION_ALREADY_APPLIED' in result.stderr for result in results))
        self.assertEqual(self.sql('SELECT count(*) FROM supabase_migrations.schema_migrations').stdout.strip(), '1')

    def test_unprivileged_role_stops_before_any_migration_effect(self):
        self.sql('CREATE ROLE cloud_unprivileged NOLOGIN;')
        prepared = self.prepare('CREATE TABLE public.cloud_fixture(value text);')
        failed = self.sql('SET ROLE cloud_unprivileged; ' + prepared['query'], check=False)
        self.assertNotEqual(failed.returncode, 0)
        self.assertIn('POS_PSQL_ROLE_ACTIVATION_FAILED', failed.stderr)
        self.assertEqual(self.sql("SELECT to_regclass('public.cloud_fixture') IS NULL").stdout.strip(), 't')
        self.assertEqual(self.sql('SELECT count(*) FROM supabase_migrations.schema_migrations').stdout.strip(), '0')

    def test_recovery_checks_real_original_and_transport_bytes_without_reapplying(self):
        prepared = self.prepare('CREATE TABLE public.cloud_fixture(value text);')
        self.sql(prepared['query'])
        self.sql('INSERT INTO supabase_migrations.schema_migrations(version,name,statements) VALUES('
                 + migration.literal('20261029112749') + ',' + migration.literal(prepared['transportName'])
                 + ',ARRAY[' + migration.literal(prepared['query']) + ']);')
        versions = json.loads(self.sql('SELECT json_agg(t) FROM (SELECT version,name FROM '
                                       'supabase_migrations.schema_migrations) t').stdout)
        def local_read(directory, operation, arguments):
            self.assertEqual(operation, 'query')
            rows = self.sql('SELECT json_agg(t) FROM (' + arguments['query'] + ') t').stdout
            return {'rows': json.loads(rows)}
        with patch.object(migration, 'request', side_effect=local_read):
            self.assertTrue(migration.verify_applied('/local-fixture', prepared, versions)['historyVerified'])
            self.sql("UPDATE supabase_migrations.schema_migrations SET statements=ARRAY['SELECT 1'] "
                     "WHERE version='20261029112749'")
            with self.assertRaises(migration.CloudError):
                migration.verify_applied('/local-fixture', prepared, versions)
        # Recovery verified existing history; no CREATE or schema replay ran.
        self.assertEqual(self.sql('SELECT count(*) FROM public.cloud_fixture').stdout.strip(), '0')


if __name__ == '__main__':
    unittest.main(verbosity=2)
