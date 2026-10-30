#!/usr/bin/env python3
"""Explicit owner exception: verify prior evidence without claiming a new PASS."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import pos_local_release_gate as gate

SUPPORT_PATHS = {
    'scripts/deploy_pos_production.sh',
    'scripts/cloud_deployment/reuse_candidate.py',
    'scripts/cloud_deployment/test_reuse_candidate.py',
    'docs/pos/CLOUD_DEPLOYMENT.md',
}
COMPAT_FIXES = {
    'supabase/migrations/20261030083248_menu_discount_quantities.sql': (
        '29a88b40dc5ce879585893a0b60b0f224884fc940375be1755d0b473ed228e0d',
        '8619316c65c805bdd971d3ec32db3079ab04ddb502abd5988c72a811937517c5'),
    'test/fixtures/menu_discount_quantities_setup.sql': (
        '25d4759ddb4ce2fa3852ce250a8e7be803689968ba3998d50ec054a0efc12865',
        '9927234b13eaa9ff84480829b97fa9883b0e3b8dff7067e4b9e879196b663f95'),
}


def changed_support_paths(before, after):
    changed = sorted(p for p in before.keys() | after.keys() if before.get(p) != after.get(p))
    for path in changed:
        gate.require(path in SUPPORT_PATHS or
                     (path in COMPAT_FIXES and (before.get(path), after.get(path)) == COMPAT_FIXES[path]),
                     'Application, SQL, build or verification inputs changed')
    return changed


def verify(evidence, sql_evidence=None):
    evidence = Path(evidence).resolve()
    original = json.loads((evidence / 'receipt.json').read_text())
    sha = original['sourceBefore']['sha']
    gate.require(len(sha) == 40 and all(c in '0123456789abcdef' for c in sha), 'Invalid candidate identity')
    current = gate.source(ROOT)
    subprocess.run(['git', 'merge-base', '--is-ancestor', sha, current['sha']], cwd=ROOT, check=True)
    names = set(subprocess.check_output(['git', 'diff', '--name-only', sha, current['sha']],
                                       cwd=ROOT, text=True).splitlines())
    gate.require(names <= SUPPORT_PATHS | COMPAT_FIXES.keys(), 'Non-support Git entries or modes changed')
    with tempfile.TemporaryDirectory(prefix='pos-owner-candidate-') as temporary:
        snapshot = Path(temporary) / 'source'
        subprocess.run(['git', 'worktree', 'add', '--detach', str(snapshot), sha], cwd=ROOT,
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            receipt = gate.verify(evidence, root=snapshot, kind='candidate')
        finally:
            subprocess.run(['git', 'worktree', 'remove', '--force', str(snapshot)], cwd=ROOT, check=True)
    changed = changed_support_paths(receipt['sourceBefore']['inputHashes'], current['inputHashes'])
    fixes = {p: current['inputHashes'][p] for p in changed if p in COMPAT_FIXES}
    sql_proof = None
    if fixes:
        gate.require(sql_evidence is not None, 'The specific SQL compatibility fix requires its own passing SQL check')
        sql_proof = json.loads(Path(sql_evidence).read_text())
        log = Path(sql_proof['log']).read_bytes()
        gate.require(sql_proof['type'] == 'discount-sql-compatibility-check'
                     and sql_proof['status'] == 'PASS' and sql_proof['exitCode'] == 0
                     and sql_proof['command'] == 'bash scripts/test_menu_discount_quantities.sh'
                     and sql_proof['inputHashes'] == fixes
                     and hashlib.sha256(log).hexdigest() == sql_proof['logSha256']
                     and log.rstrip().endswith(b'MENU_DISCOUNT_QUANTITIES_SQL_TEST=PASS'),
                     'SQL compatibility proof is missing, failed or stale')
    gate.require(gate.source(ROOT) == current, 'Source changed while checking the owner exception')
    return {'type': 'pos-owner-repeat-verification-waiver', 'status': 'NOT_RUN_OWNER_WAIVER',
            'candidateSourceSha': sha, 'releaseSourceSha': current['sha'],
            'candidateVerificationStatus': 'PASS', 'applicationInputsVerified': True,
            'changedReleaseSupportPaths': [p for p in changed if p in SUPPORT_PATHS],
            'sqlCompatibilityFixes': fixes, 'sqlCompatibilityEvidence': sql_proof,
            'candidateReceiptSha256': hashlib.sha256((evidence / 'receipt.json').read_bytes()).hexdigest(),
            'candidateEvidence': str(evidence), 'reason': 'Owner explicitly requested stopping repeated verification and deploying.'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--evidence', required=True)
    parser.add_argument('--record', required=True)
    parser.add_argument('--sql-evidence')
    args = parser.parse_args()
    try:
        result = verify(args.evidence, args.sql_evidence)
        Path(args.record).write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result, sort_keys=True))
    except (gate.InvalidEvidence, OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        raise SystemExit('OWNER_CANDIDATE_REUSE_BLOCKED: ' + str(error))
