import copy
import hashlib
import shlex
import datetime as dt
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import socket
import socketserver
import threading
import sys
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent))
from evidence import InvalidEvidence, evidence_file, flutter_counts, parse_counts, sha256, deno_counts, node_counts
import pos_local_release_gate as gate

loader = importlib.machinery.SourceFileLoader('fixture_docker', str(HERE / 'docker'))
spec = importlib.util.spec_from_loader(loader.name, loader)
fixture_docker = importlib.util.module_from_spec(spec)
loader.exec_module(fixture_docker)


def suite(name='real test', skipped=False, terminal=True):
    events = [{'type': 'testStart', 'test': {'id': 1, 'name': name}},
              {'type': 'testDone', 'testID': 1, 'result': 'success', 'hidden': False, 'skipped': skipped}]
    if terminal:
        events.append({'type': 'done', 'success': True})
    return '\n'.join(json.dumps(x) for x in events) + '\n'


def summaries():
    return ('ok | 4 passed | 0 failed (20ms)\n' * 9 +
            '# tests 3\n# pass 3\n# fail 0\n# cancelled 0\n# skipped 0\n# todo 0\n')


class ProcessOutputTests(unittest.TestCase):
    def test_real_nonzero_process_cannot_be_hidden_by_success_text(self):
        with tempfile.TemporaryDirectory() as p:
            result = gate.recorded(Path(p), 'exit', [sys.executable, '-c',
                "print('PASS'); raise SystemExit(17)"], 5)
            self.assertEqual(result['exitCode'], 17)
            self.assertEqual(result['logSha256'], sha256(Path(p) / 'exit.log'))

    def test_timeout_records_failure_despite_partial_output(self):
        with tempfile.TemporaryDirectory() as p:
            result = gate.recorded(Path(p), 'timeout', [sys.executable, '-u', '-c',
                "import time; print('PASS'); time.sleep(30)"], .05)
            self.assertEqual(result['exitCode'], 124)

    def test_visible_completed_assertions_required(self):
        self.assertEqual(flutter_counts(suite())['passed'], 1)
        for text in ['', '{"type":"done","success":true}\n', suite(terminal=False),
                     suite().replace('"success": true', '"success": false'),
                     suite().replace('"hidden": false', '"hidden": true'),
                     suite() + '{"type":"done","success":true}\n',
                     suite() + '{"type":"error","error":"fixture"}\n']:
            with self.subTest(text=text), self.assertRaises(InvalidEvidence):
                flutter_counts(text)

    def test_unknown_duplicate_failed_or_unfinished_tests_rejected(self):
        for text in [suite().replace('"testID": 1', '"testID": 2'),
                     suite().replace('"result": "success"', '"result": "failure"'),
                     suite().replace('{"type": "done"', '{"type":"testStart","test":{"id":2,"name":"unfinished"}}\n{"type": "done"'),
                     suite().replace('{"type": "done"', '{"type":"testDone","testID":1,"result":"success"}\n{"type": "done"')]:
            with self.subTest(text=text), self.assertRaises(InvalidEvidence):
                flutter_counts(text)

    def test_skips_require_a_real_later_success_or_exact_native_exclusion(self):
        with self.assertRaises(InvalidEvidence):
            flutter_counts(suite('fixture SQL', skipped=True) + suite('different test'), suites=2, repository=True)
        value = flutter_counts(suite('fixture SQL', skipped=True) + suite('fixture SQL'), suites=2, repository=True)
        self.assertEqual(value['reexecutedWithSqlFixture'], 1)
        name = 'Windows connection probe sends no bytes and preserves spooler error'
        value = flutter_counts(suite(name, skipped=True) + suite(), suites=2, repository=True)
        self.assertEqual(value['notApplicableOnLinux'], [name])
        with self.assertRaises(InvalidEvidence):
            flutter_counts(suite(name, skipped=True) + suite(), suites=2)

    def test_repository_marker_order_and_final_completion_required(self):
        with tempfile.TemporaryDirectory() as p:
            root = Path(p)
            (root / 'scripts').mkdir()
            (root / 'scripts/check_repo.sh').write_text(
                "printf 'CHECK_REPO_STEP=first\\n'\nprintf 'CHECK_REPO_STEP=store_operating_current_schema_upgrade\\n'\nprintf 'CHECK_REPO_STEP=last\\n'\n")
            text = 'CHECK_REPO_STEP=first\n' + suite() * 3 + summaries() + 'CHECK_REPO_STEP=last\nCHECK_REPO_COMPLETE\n'
            self.assertEqual(parse_counts({'format':'repository'}, text, root)['completedSuites'], 3)
            for broken in [text.replace('CHECK_REPO_STEP=last\n', ''), text.replace('last', 'first'),
                           text.replace('CHECK_REPO_COMPLETE\n', ''), text + 'late unverified command\n']:
                with self.subTest(broken=broken), self.assertRaises(InvalidEvidence):
                    parse_counts({'format':'repository'}, broken, root)

    def test_nonempty_unittest_assertions_and_no_skipped_results(self):
        self.assertEqual(parse_counts({'format':'unittest'}, 'Ran 9 tests in 0.1s\n\nOK\n', HERE)['passed'], 9)
        for text in ['Ran 0 tests in 0.1s\nOK', 'Ran 3 tests in 0.1s\nOK (skipped=1)', 'not ok 1 - role leak']:
            with self.assertRaises(InvalidEvidence):
                parse_counts({'format':'unittest'}, text, HERE)

    def test_deno_requires_nonempty_complete_suites_without_ignored_tests(self):
        self.assertEqual(deno_counts('ok | 4 passed | 0 failed (2ms)')['passed'], 4)
        for text in ['', 'ok | 0 passed | 0 failed', 'ok | 4 passed | 1 failed',
                     'ok | 4 passed | 0 failed | 1 ignored', 'ok | 4 passed | 0 failed\n'*2]:
            with self.subTest(text=text), self.assertRaises(InvalidEvidence): deno_counts(text)

    def test_node_requires_all_counters_and_no_skipped_or_failed_tests(self):
        text = summaries().split('# tests')[1]
        text = '# tests'+text
        self.assertEqual(node_counts(text)['passed'], 3)
        for broken in [text.replace('# fail 0','# fail 1'), text.replace('# skipped 0','# skipped 1'),
                       text.replace('# pass 3','# pass 0'), text.replace('# todo 0\n','')]:
            with self.subTest(text=broken), self.assertRaises(InvalidEvidence): node_counts(broken)

    def test_real_loopback_proxy_relays_bytes_to_fixture_and_closes_on_failure(self):
        class Echo(socketserver.BaseRequestHandler):
            def handle(self):
                self.request.sendall(self.request.recv(1024).upper())
        with socketserver.ThreadingTCPServer(('127.0.0.1',0), Echo) as server:
            threading.Thread(target=server.serve_forever,daemon=True).start()
            listener = socket.socket(); listener.bind(('127.0.0.1',0)); listener.listen(4)
            process = subprocess.Popen([sys.executable,'-B',str(HERE/'port_proxy.py'),str(listener.fileno()),
                '127.0.0.1',str(server.server_address[1])],pass_fds=(listener.fileno(),))
            try:
                with socket.create_connection(listener.getsockname(),timeout=5) as client:
                    client.sendall(b'fixture-only'); self.assertEqual(client.recv(1024),b'FIXTURE-ONLY')
            finally:
                process.terminate(); process.wait(timeout=5); listener.close(); server.shutdown()

    def test_optional_external_checkout_is_never_counted_as_a_pass(self):
        name = 'historical Deliberry -> POS -> Office data flow harness optional historical Office import read fences from external checkout'
        result = flutter_counts(suite(name,skipped=True)+suite('POS assertions'),suites=2,repository=True)
        self.assertEqual(result['passed'],1)
        self.assertEqual(result['unavailableOptionalCrossRepository'],[name])
        with self.assertRaises(InvalidEvidence): flutter_counts(suite(name,skipped=True)+suite(),suites=2)


class IntegrityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.directory = Path(self.temp.name)
        self.root = gate.ROOT
        self.recipe = gate.recipe(self.root)
        self.source = {'sha': 'a'*40, 'fingerprint': 'b'*64}
        self.value = {'schemaVersion':1, 'type':'pos-local-verification', 'kind':'candidate',
            'runId':'c'*32, 'completed':True, 'status':'PASS',
            'startedAt':(dt.datetime.now(dt.timezone.utc)-dt.timedelta(minutes=2)).isoformat(),
            'finishedAt':(dt.datetime.now(dt.timezone.utc)-dt.timedelta(seconds=1)).isoformat(),
            'sourceBefore':self.source, 'sourceAfter':self.source,
            'contractSha256':gate.contract_hash(self.root), 'steps':[]}
        linux = dict(self.recipe['tools'], osId='ubuntu', osVersion='24.04', arch='x86_64')
        self.value['environment'] = {'linux':linux, 'image':{'Os':'linux','Architecture':'amd64'},
            'fixtureImages':[{'Id':'sha256:'+'e'*64,'Os':'linux','Architecture':'arm64','RepoDigests':[]}]}
        nested = self.directory/'nested'; nested.mkdir()
        (nested/'fixture-images.jsonl').write_text(json.dumps({'runId':'c'*32,'imageId':'sha256:'+'e'*64})+'\n')
        for name, text in [('imageBuild', 'build succeeded\n'), ('toolProbe', json.dumps(linux)+'\n')]:
            log = self.directory / (name + '.log'); log.write_text(text)
            self.value[name] = {'exitCode':0,'log':log.name,'logSha256':sha256(log)}
        source = (self.root / 'scripts/check_repo.sh').read_text()
        import re
        markers = re.findall(r"printf 'CHECK_REPO_STEP=([a-z0-9_]+)\\n'", source)
        markers.remove('store_operating_current_schema_upgrade')
        outputs = {'unittest':'Ran 12 tests in 0.1s\n\nOK\n', 'flutter':suite(),
            'command':'Actual isolated SQL assertions completed\n',
            'deno':'ok | 4 passed | 0 failed (20ms)\n',
            'repository':''.join('CHECK_REPO_STEP='+x+'\n' for x in markers)+suite()*3+summaries()+'CHECK_REPO_COMPLETE\n'}
        for step in self.recipe['steps']:
            log = self.directory / (step['id'] + '.log'); log.write_text(outputs[step['format']])
            self.value['steps'].append({'id':step['id'],'argv':step['argv'],'sourceSha':'a'*40,
                'startedAt':self.value['startedAt'],'finishedAt':self.value['startedAt'],
                'command':shlex.join(step['argv']),
                'commandSha256':hashlib.sha256(json.dumps(step['argv']).encode()).hexdigest(),
                'durationMs':0,'exitCode':0,'log':log.name,'logSha256':sha256(log),
                'counts':parse_counts(step,log.read_text(),self.root)})
        self.value['artifacts'] = []
        for name in ['index.html','main.dart.js','flutter_bootstrap.js','photo_import_worker.js']:
            f = self.directory / 'artifacts/web' / name; f.parent.mkdir(parents=True,exist_ok=True); f.write_text('fixture artifact\n')
            self.value['artifacts'].append({'path':str(f.relative_to(self.directory)), 'bytes':f.stat().st_size,'sha256':sha256(f)})

    def tearDown(self):
        self.temp.cleanup()

    def verify(self, value=None, **kwargs):
        gate.write_receipt(self.directory, value or self.value)
        with patch.object(gate, 'source', return_value=self.source):
            return gate.verify(self.directory, self.root, **kwargs)

    def test_complete_fixture_validates_but_is_not_a_production_authorization(self):
        self.assertEqual(self.verify()['sourceBefore'], self.source)
        with self.assertRaises(InvalidEvidence): self.verify(kind='exact-main')
        with self.assertRaises(InvalidEvidence): self.verify(run_id='different invocation')

    def test_failed_interrupted_missing_reordered_changed_steps_block(self):
        for change in ['failed','partial','missing','reorder','command','executed-command','count','sha','recipe','time']:
            v = copy.deepcopy(self.value)
            if change == 'failed': v['steps'][0]['exitCode'] = 1
            elif change == 'partial': v['completed'] = False
            elif change == 'missing': v['steps'].pop()
            elif change == 'reorder': v['steps'].reverse()
            elif change == 'command': v['steps'][0]['argv'] = ['true']
            elif change == 'executed-command': v['steps'][0]['command'] = 'true'
            elif change == 'count': v['steps'][0]['counts']['passed'] += 1
            elif change == 'sha': v['sourceAfter'] = {'sha':'d'*40}
            elif change == 'recipe': v['contractSha256'] = 'd'*64
            elif change == 'time': v['finishedAt'] = '2020-01-01T00:00:00+00:00'
            with self.subTest(change=change), self.assertRaises(InvalidEvidence): self.verify(v)

    def test_missing_or_tampered_logs_and_artifacts_block(self):
        for record in [self.value['steps'][0], self.value['toolProbe'], self.value['imageBuild']]:
            path = self.directory / record['log']; original = path.read_bytes()
            path.write_text('replacement PASS\n')
            with self.assertRaises(InvalidEvidence): self.verify()
            path.unlink()
            with self.assertRaises(InvalidEvidence): self.verify()
            path.write_bytes(original)
        f = self.directory / self.value['artifacts'][0]['path']; f.write_text('tampered artifact')
        with self.assertRaises(InvalidEvidence): self.verify()

    def test_path_traversal_and_symlink_evidence_block(self):
        with self.assertRaises(InvalidEvidence): evidence_file(self.directory, '../outside')
        with self.assertRaises(InvalidEvidence): evidence_file(self.directory, '/etc/passwd')
        link = self.directory/'link'; link.symlink_to(self.directory/'imageBuild.log')
        with self.assertRaises(InvalidEvidence): evidence_file(self.directory, 'link')

    def test_wrong_os_architecture_or_tool_version_blocks(self):
        for key in ['osId','osVersion','arch','flutter','node','dart','deno','chrome']:
            environment = copy.deepcopy(self.value['environment']['linux']); environment[key] = 'wrong'
            with self.subTest(key=key), self.assertRaises(InvalidEvidence): gate.validate_tools(environment, self.recipe)

    def test_real_dirty_source_and_uncommitted_files_block(self):
        p = self.directory/'repo'; p.mkdir()
        subprocess.run(['git','init','--quiet',str(p)],check=True)
        subprocess.run(['git','-C',str(p),'config','user.email','local-fixture@example.invalid'],check=True)
        subprocess.run(['git','-C',str(p),'config','user.name','Local fixture'],check=True)
        (p/'source').write_text('committed\n')
        subprocess.run(['git','-C',str(p),'add','.'],check=True)
        subprocess.run(['git','-C',str(p),'commit','--quiet','-m','fixture'],check=True)
        baseline = gate.source(p)
        (p/'source').write_text('changed\n')
        with self.assertRaises(InvalidEvidence): gate.source(p)
        (p/'source').write_text('committed\n'); (p/'untracked').write_text('new source')
        with self.assertRaises(InvalidEvidence): gate.source(p)
        self.assertEqual(baseline['inputHashes'].keys(), {'source'})


class FixtureOwnershipTests(unittest.TestCase):
    def test_every_created_fixture_is_labelled(self):
        with patch.object(fixture_docker.subprocess, 'run') as execute:
            execute.return_value.returncode = 1
            args = fixture_docker.prepare(['run','--name','owned','postgres:15'], 'f'*32)
            self.assertIn('pos.local.verification='+'f'*32, args)
            self.assertIn('pos.local.verification='+'f'*32,
                fixture_docker.prepare(['network','create','owned-net'], 'f'*32))

    def test_resource_collision_or_foreign_ownership_refuses_cleanup_and_exec(self):
        with patch.object(fixture_docker.subprocess, 'run') as execute:
            execute.return_value.returncode = 0
            execute.return_value.stdout = '[{"Config":{"Labels":{"pos.local.verification":"foreign"}}}]'
            for args in [['run','--name','existing','postgres:15'], ['rm','-f','existing'],
                         ['exec','-e','FIXTURE=value','existing','psql'], ['logs','--tail','20','existing']]:
                with self.subTest(args=args), self.assertRaises(ValueError):
                    fixture_docker.prepare(args,'f'*32)


    def test_network_links_validate_both_owned_endpoints_before_execution(self):
        for operation in ['connect','disconnect']:
            with patch.object(fixture_docker,'owned') as owned:
                args = ['network',operation,'owned-network','owned-container']
                self.assertEqual(fixture_docker.prepare(args,'f'*32),args)
                self.assertEqual(owned.call_args_list,[unittest.mock.call('network','owned-network','f'*32),
                                                    unittest.mock.call('container','owned-container','f'*32)])
            with patch.object(fixture_docker,'owned',side_effect=[None,ValueError('foreign container')]):
                with self.assertRaises(ValueError): fixture_docker.prepare(args,'f'*32)

    def test_unreviewed_or_unnamed_operations_refused(self):
        for args in [['system','prune'],['volume','prune'],['image','prune'],['tag','foreign','other'],['run','postgres:15']]:
            with self.assertRaises(ValueError): fixture_docker.prepare(args,'f'*32)


if __name__ == '__main__':
    unittest.main()
