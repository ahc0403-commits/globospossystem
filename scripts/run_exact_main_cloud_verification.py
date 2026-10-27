#!/usr/bin/env python3
"""Run the release-contract checks against clean, freshly fetched exact main.

This is a preparation tool, not yet a replacement for the production check gate.
Evidence is private to the executor and must be reviewed before sharing.
"""
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
COMMANDS = (
    ('repository', ['bash', 'scripts/check_repo.sh']),
    ('browser_terminal_auth', ['flutter', 'test', '--no-pub', '--platform', 'chrome',
                               'test/terminal_auth_browser_test.dart']),
)


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def git(*args):
    return subprocess.check_output(['git', '-C', str(ROOT), *args], text=True).strip()


def clean_sha():
    sha = git('rev-parse', 'HEAD')
    if git('status', '--porcelain', '--untracked-files=all'):
        raise RuntimeError('worktree is not clean')
    if sha != git('rev-parse', 'refs/remotes/origin/main'):
        raise RuntimeError('HEAD does not equal freshly fetched origin/main')
    return sha


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    if len(sys.argv) != 1:
        raise RuntimeError('this verifier accepts no arguments or check overrides')
    subprocess.run(['git', '-C', str(ROOT), 'fetch', '--quiet', 'origin',
                    '+refs/heads/main:refs/remotes/origin/main'], check=True)
    sha = clean_sha()
    # Keep potentially sensitive test logs out of the checkout and private by default.
    evidence = Path(tempfile.mkdtemp(prefix='pos-exact-main-'))
    evidence.chmod(0o700)
    results = {
        'sha': sha, 'kind': 'exact-main', 'started_utc': utc_now(),
        'os': platform.platform(), 'architecture': platform.machine(),
        'checks': [], 'status': 'incomplete',
        'optional_checks': {'current_schema_upgrade': 'not supplied; verify separately when applicable'},
        'locks': {}, 'tools': {},
    }
    metadata = evidence / 'evidence.json'
    print(f'Evidence directory (private; review before sharing): {evidence}', flush=True)
    try:
        for name in ('pubspec.lock', 'scripts/package-lock.json'):
            results['locks'][name] = digest(ROOT / name)
        for name, command in (
            ('git', ['git', '--version']), ('flutter', ['flutter', '--version']),
            ('dart', ['dart', '--version']), ('node', ['node', '--version']),
            ('deno', ['deno', '--version']), ('python', [sys.executable, '--version']),
            ('docker', ['docker', '--version']), ('psql', ['psql', '--version']),
        ):
            version = subprocess.run(command, cwd=ROOT, text=True, capture_output=True, check=True)
            results['tools'][name] = (version.stdout + version.stderr).strip()
        if not results['tools']['flutter'].startswith('Flutter 3.41.6 '):
            raise RuntimeError('Flutter 3.41.6 is required by the release contract')
        if not results['tools']['node'].startswith('v22.'):
            raise RuntimeError('Node 22 is required by the release contract')
        if not results['tools']['deno'].startswith('deno 2.7.13 '):
            raise RuntimeError('Deno 2.7.13 is required by the release contract')
        # No production credentials or arbitrary caller test flags are inherited.
        allowed = ('PATH', 'HOME', 'TMPDIR', 'LANG', 'LC_ALL', 'CHROME_EXECUTABLE',
                   'PUB_CACHE', 'FLUTTER_ROOT', 'ANDROID_HOME', 'ANDROID_SDK_ROOT')
        env = {key: os.environ[key] for key in allowed if key in os.environ}
        for name, command in COMMANDS:
            log = evidence / f'{name}.log'
            item = {'name': name, 'command': command, 'started_utc': utc_now()}
            results['checks'].append(item)
            print(f'Running {name}: {" ".join(command)}', flush=True)
            with log.open('wb') as output:
                os.chmod(log, 0o600)
                proc = subprocess.run(command, cwd=ROOT, env=env, stdout=output,
                                      stderr=subprocess.STDOUT, check=False)
            item.update(ended_utc=utc_now(), exit_code=proc.returncode,
                        log=str(log), log_sha256=digest(log))
            if proc.returncode:
                raise RuntimeError(f'{name} failed with exit code {proc.returncode}')
            if clean_sha() != sha:
                raise RuntimeError('source SHA changed during verification')
        # A long-running check must not certify a main that advanced meanwhile.
        subprocess.run(['git', '-C', str(ROOT), 'fetch', '--quiet', 'origin',
                        '+refs/heads/main:refs/remotes/origin/main'], check=True)
        if clean_sha() != sha:
            raise RuntimeError('origin/main changed during verification')
        results['status'] = 'passed'
    finally:
        results['ended_utc'] = utc_now()
        results['command_counts'] = {
            'planned': len(COMMANDS), 'run': len(results['checks']),
            'passed': sum(item.get('exit_code') == 0 for item in results['checks']),
            'failed': sum(item.get('exit_code') not in (None, 0) for item in results['checks']),
            'not_run': len(COMMANDS) - len(results['checks']),
        }
        results['individual_test_counts'] = 'not extracted; inspect complete logs for failures and skips'
        metadata.write_text(json.dumps(results, indent=2) + '\n')
        metadata.chmod(0o600)
        print(f'Evidence manifest: {metadata}', flush=True)
        print(f'Evidence manifest SHA-256: {digest(metadata)}', flush=True)
    print(f'Exact-main verification passed: {sha}', flush=True)


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, subprocess.CalledProcessError) as exc:
        print(f'Exact-main verification failed: {exc}', file=sys.stderr)
        sys.exit(1)
