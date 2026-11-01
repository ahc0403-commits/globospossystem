import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('runtime_catalog', Path(__file__).parents[1] / 'runtime_catalog.py')
m = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(m)


def obj(kind, identity, detail):
    return {'kind': kind, 'identity': identity, 'detail': detail,
            'sha256': m.digest(m.pg_jsonb(detail).encode())}


def snapshot():
    return {'schemaVersion': 1, 'kind': 'runtime-catalog', 'capturedAt': '2026-11-01T00:00:00Z',
            'serverVersion': '17.6', 'searchPath': 'public', 'database': 'postgres', 'schemas': ['public'],
            'objectCount': 2, 'limitExceeded': False, 'restorableSchema': False, 'businessDataCollected': False,
            'objects': [obj('schema', 'public', {'owner': 'postgres', 'acl': None}),
                        obj('migration', '001', {'name': 'fixture', 'statementsHash': 'a' * 64})]}


def record(data=None, project='pos'):
    data = data or snapshot()
    return {'kind': 'runtime-catalog-record', 'projectRef': m.PROJECTS[project],
            'snapshot': data, 'catalogSha256': m.catalog_hash(data)}


class RuntimeCatalogTest(unittest.TestCase):
    def test_valid_catalog(self):
        self.assertEqual(m.validate(snapshot())['objectCount'], 2)

    def test_postgres_jsonb_canonical_order_and_utf8(self):
        self.assertEqual(m.pg_jsonb({'aa': True, 'z': None, 'b': ['한글', 1]}),
                         '{"b": ["한글", 1], "z": null, "aa": true}')

    def test_truncated_or_incomplete_snapshots_are_rejected(self):
        for key, value in [('limitExceeded', True), ('objectCount', 3), ('objects', []),
                           ('restorableSchema', True), ('businessDataCollected', True)]:
            data = snapshot()
            data[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                m.validate(data)

    def test_unknown_envelope_and_body_fields_are_rejected(self):
        data = snapshot()
        data['password'] = 'must-not-enter-output'
        with self.assertRaises(ValueError): m.validate(data)
        data = snapshot()
        data['objects'][0]['detail']['functionBody'] = 'must-not-enter-output'
        with self.assertRaises(ValueError): m.validate(data)

    def test_tampered_detail_is_rejected(self):
        data = snapshot()
        data['objects'][0]['detail']['owner'] = 'other_actor'
        with self.assertRaises(ValueError): m.validate(data)

    def test_duplicate_objects_are_rejected(self):
        data = snapshot()
        data['objects'].append(copy.deepcopy(data['objects'][0]))
        data['objectCount'] += 1
        with self.assertRaises(ValueError): m.validate(data)

    def test_missing_public_or_migration_history_is_rejected(self):
        for index in (0, 1):
            data = snapshot()
            del data['objects'][index]
            data['objectCount'] -= 1
            with self.assertRaises(ValueError): m.validate(data)

    def test_read_accepts_only_single_complete_snapshot(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'snapshot.json'
            path.write_text(json.dumps([{'snapshot': snapshot()}]))
            self.assertEqual(m.read(path)['objectCount'], 2)
            path.write_text(json.dumps([{'snapshot': snapshot()}, {'snapshot': snapshot()}]))
            with self.assertRaises(ValueError): m.read(path)

    def test_comparison_detects_change_addition_and_removal(self):
        data = snapshot()
        data['objects'][0] = obj('schema', 'public', {'owner': 'new_owner', 'acl': None})
        data['objects'][1] = obj('migration', '002', {'name': 'new', 'statementsHash': 'b' * 64})
        diff = m.compare(record(), record(data))
        self.assertEqual(diff['changed'], [['schema', 'public']])
        self.assertEqual(diff['added'], [['migration', '002']])
        self.assertEqual(diff['removed'], [['migration', '001']])
        self.assertFalse(diff['businessBehaviorVerified'])

    def test_cross_project_and_engine_changes_rejected(self):
        with self.assertRaises(ValueError): m.compare(record(), record(project='office'))
        data = snapshot()
        data['serverVersion'] = '18.0'
        with self.assertRaises(ValueError): m.compare(record(), record(data))

    def test_captured_time_and_input_order_do_not_change_catalog_hash(self):
        data = snapshot()
        data['capturedAt'] = '2026-11-02T00:00:00Z'
        data['objects'].reverse()
        self.assertEqual(m.catalog_hash(data), m.catalog_hash(snapshot()))

    def test_recorded_hash_tampering_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'record.json'
            data = record()
            data['catalogSha256'] = '0' * 64
            path.write_text(json.dumps(data))
            with self.assertRaises(ValueError): m.read(path)


if __name__ == '__main__':
    unittest.main()
