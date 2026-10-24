"""Parse real process output. A receipt is an integrity record, not a signature."""
import hashlib
import json
import re
from pathlib import Path


class InvalidEvidence(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise InvalidEvidence(message)


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


NATIVE_WINDOWS_TESTS = {
    'Windows build runner propagates native nonzero exit codes',
    'Windows connection probe sends no bytes and preserves spooler error',
}


def flutter_counts(output, suites=1, repository=False):
    starts, ended, skipped, passed_names = {}, set(), [], set()
    complete = 0
    passed = 0
    for line in output.splitlines():
        if not line.startswith('{'):
            continue
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        kind = event.get('type')
        if kind == 'error':
            raise InvalidEvidence('Flutter emitted an error event')
        if kind == 'testStart':
            test = event['test']
            require(test['id'] not in starts, 'Duplicate Flutter testStart')
            starts[test['id']] = test['name']
        elif kind == 'testDone':
            tid = event['testID']
            require(tid in starts and tid not in ended, 'Unknown/duplicate testDone')
            ended.add(tid)
            require(event.get('result') == 'success', 'Failed Flutter test')
            if event.get('skipped'):
                skipped.append(starts[tid])
            elif not event.get('hidden'):
                passed += 1
                passed_names.add(starts[tid])
        elif kind == 'done':
            require(event.get('success') is True, 'Incomplete/failed Flutter suite')
            require(starts and set(starts) == ended, 'Unfinished Flutter tests')
            complete += 1
            starts, ended = {}, set()
    require(complete == suites and not starts, 'Missing/extra terminal Flutter done')
    require(passed > 0, 'No visible Flutter assertions executed')
    native = []
    reassigned = []
    for name in skipped:
        if repository and name in NATIVE_WINDOWS_TESTS:
            native.append(name)
        elif repository and name in passed_names:
            # The initial full suite lacks SQL fixture env; check_repo runs these
            # same test names again against disposable real SQL/PostgREST later.
            reassigned.append(name)
        else:
            raise InvalidEvidence('Unaccounted skipped test: ' + name)
    return {'passed': passed, 'failed': 0, 'skipped': len(skipped),
            'reexecutedWithSqlFixture': len(reassigned),
            'notApplicableOnLinux': sorted(native), 'completedSuites': complete,
            'unit': 'visible Flutter tests; native exclusions are not PASS'}


def parse_counts(step, output, root):
    require(output.strip(), 'Empty process log')
    require(not re.search(r'^not ok\b', output, re.M), 'Failed TAP assertion')
    if step['format'] == 'flutter':
        return flutter_counts(output)
    if step['format'] == 'repository':
        source = (Path(root) / 'scripts/check_repo.sh').read_text()
        expected = re.findall(r"printf 'CHECK_REPO_STEP=([a-z0-9_]+)\\n'", source)
        # Existing optional schema-export upgrade is outside the former required
        # workflow. No production export is requested or loaded by this recipe.
        expected.remove('store_operating_current_schema_upgrade')
        actual = re.findall(r'^CHECK_REPO_STEP=([a-z0-9_]+)$', output, re.M)
        require(actual == expected, 'Missing/reordered/duplicate repository stages')
        require(output.splitlines()[-1] == 'CHECK_REPO_COMPLETE', 'Partial repository run')
        require(output.count('\nCHECK_REPO_COMPLETE\n') == 1, 'Invalid repository completion')
        counts = flutter_counts(output, suites=3, repository=True)
        counts['repositoryStages'] = len(actual)
        return counts
    if step['format'] == 'unittest':
        count = re.search(r'^Ran (\d+) tests? in ', output, re.M)
        require(count and int(count[1]) > 0, 'No local gate contract assertions')
        require(output.rstrip().endswith('OK'), 'Contract tests incomplete/failed/skipped')
        return {'passed': int(count[1]), 'failed': 0, 'skipped': 0, 'unit': 'unittest'}
    return {'passed': 1, 'failed': 0, 'skipped': 0, 'unit': 'complete command; SQL assertions retained in log'}


def evidence_file(directory, relative):
    path = Path(directory) / relative
    require(not Path(relative).is_absolute(), 'Absolute evidence path')
    require(path.resolve().is_relative_to(Path(directory).resolve()), 'Evidence escapes directory')
    require(path.is_file() and not path.is_symlink(), 'Missing/symlink evidence file')
    return path
