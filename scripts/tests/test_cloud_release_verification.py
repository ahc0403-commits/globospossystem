import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'run_exact_main_cloud_verification.py'


class ExactMainVerificationTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.base = Path(self.tmp.name)
        self.origin = self.base / 'origin.git'
        self.repo = self.base / 'repo'
        self.bin = self.base / 'bin'
        self.bin.mkdir()
        subprocess.run(['git', 'init', '--bare', '--initial-branch=main', str(self.origin)], check=True, stdout=subprocess.DEVNULL)
        subprocess.run(['git', 'init', '--initial-branch=main', str(self.repo)], check=True, stdout=subprocess.DEVNULL)
        self.git('config', 'user.email', 'fixture@example.test')
        self.git('config', 'user.name', 'Fixture')
        (self.repo / 'scripts').mkdir()
        shutil.copy(SOURCE, self.repo / 'scripts' / SOURCE.name)
        (self.repo / 'scripts' / 'check_repo.sh').write_text(
            'if [ -f "$HOME/fail-repo" ]; then exit 4; fi\n'
            'if [ -f "$HOME/change-repo" ]; then echo dirty >> pubspec.lock; fi\n'
            'echo repository-pass\n')
        (self.repo / 'pubspec.lock').write_text('fixture\n')
        (self.repo / 'scripts' / 'package-lock.json').write_text('{}\n')
        for name in ('flutter', 'dart', 'node', 'deno', 'docker', 'psql'):
            program = self.bin / name
            version = {'flutter': 'Flutter 3.41.6 fixture', 'node': 'v22.0.0',
                       'deno': 'deno 2.7.13 fixture'}.get(name, 'fixture-version')
            program.write_text('#!/bin/sh\nif [ "$1" = test ] && [ -f "$HOME/fail-browser" ]; then exit 3; fi\necho "' + version + '"\n')
            program.chmod(0o755)
        self.git('add', '.')
        self.git('commit', '-m', 'fixture')
        self.git('remote', 'add', 'origin', str(self.origin))
        self.git('push', '-u', 'origin', 'main')
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ['PATH'], HOME=str(self.base), TMPDIR=str(self.base))

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args):
        return subprocess.run(['git', '-C', str(self.repo), *args], check=True, capture_output=True, text=True).stdout.strip()

    def run_verifier(self, *args):
        return subprocess.run([sys.executable, str(self.repo / 'scripts' / SOURCE.name), *args], env=self.env, capture_output=True, text=True)

    def evidence(self, output):
        match = re.search(r'Evidence manifest: (.+)', output)
        self.assertIsNotNone(match, output)
        path = Path(match.group(1))
        return json.loads(path.read_text()), path

    def test_success_records_both_commands_and_hashes(self):
        result = self.run_verifier()
        self.assertEqual(result.returncode, 0, result.stderr)
        data, manifest = self.evidence(result.stdout)
        self.assertEqual(data['sha'], self.git('rev-parse', 'HEAD'))
        self.assertEqual(data['status'], 'passed')
        self.assertEqual(data['command_counts']['passed'], 2)
        for check in data['checks']:
            self.assertEqual(hashlib.sha256(Path(check['log']).read_bytes()).hexdigest(), check['log_sha256'])
        self.assertEqual(manifest.stat().st_mode & 0o777, 0o600)

    def test_browser_failure_is_not_pass(self):
        (self.base / 'fail-browser').touch()
        result = self.run_verifier()
        self.assertNotEqual(result.returncode, 0)
        data, _ = self.evidence(result.stdout)
        self.assertEqual(data['status'], 'incomplete')
        self.assertEqual(data['checks'][-1]['exit_code'], 3)
        self.assertEqual(data['command_counts']['failed'], 1)

    def test_repository_failure_stops_before_browser(self):
        (self.base / 'fail-repo').touch()
        result = self.run_verifier()
        self.assertNotEqual(result.returncode, 0)
        data, _ = self.evidence(result.stdout)
        self.assertEqual(data['checks'][0]['exit_code'], 4)
        self.assertEqual(data['command_counts']['not_run'], 1)

    def test_source_changes_during_check_stop_verification(self):
        (self.base / 'change-repo').touch()
        result = self.run_verifier()
        self.assertNotEqual(result.returncode, 0)
        data, _ = self.evidence(result.stdout)
        self.assertEqual(data['status'], 'incomplete')
        self.assertEqual(data['command_counts']['not_run'], 1)

    def test_dirty_checkout_and_arguments_fail_closed(self):
        (self.repo / 'untracked').touch()
        result = self.run_verifier()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('worktree is not clean', result.stderr)
        self.assertNotEqual(self.run_verifier('--skip').returncode, 0)

    def test_moved_main_is_rejected_after_fetch(self):
        self.git('checkout', '-b', 'feature')
        (self.repo / 'other').write_text('next\n')
        self.git('add', 'other')
        self.git('commit', '-m', 'advance')
        self.git('push', 'origin', 'HEAD:main')
        self.git('checkout', 'main')
        result = self.run_verifier()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('HEAD does not equal freshly fetched origin/main', result.stderr)


if __name__ == '__main__':
    unittest.main()
