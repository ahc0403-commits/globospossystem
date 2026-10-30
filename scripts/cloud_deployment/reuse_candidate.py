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


def changed_support_paths(before, after):
    changed = sorted(p for p in before.keys() | after.keys() if before.get(p) != after.get(p))
    gate.require(set(changed) <= SUPPORT_PATHS, 'Application, SQL, build or verification inputs changed')
    return changed


def verify(evidence):
    evidence = Path(evidence).resolve()
    original = json.loads((evidence / 'receipt.json').read_text())
    sha = original['sourceBefore']['sha']
    gate.require(len(sha) == 40 and all(c in '0123456789abcdef' for c in sha), 'Invalid candidate identity')
    current = gate.source(ROOT)
    subprocess.run(['git', 'merge-base', '--is-ancestor', sha, current['sha']], cwd=ROOT, check=True)
    names = set(subprocess.check_output(['git', 'diff', '--name-only', sha, current['sha']],
                                       cwd=ROOT, text=True).splitlines())
    gate.require(names <= SUPPORT_PATHS, 'Non-support Git entries or modes changed')
    with tempfile.TemporaryDirectory(prefix='pos-owner-candidate-') as temporary:
        snapshot = Path(temporary) / 'source'
        subprocess.run(['git', 'worktree', 'add', '--detach', str(snapshot), sha], cwd=ROOT,
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            receipt = gate.verify(evidence, root=snapshot, kind='candidate')
        finally:
            subprocess.run(['git', 'worktree', 'remove', '--force', str(snapshot)], cwd=ROOT, check=True)
    changed = changed_support_paths(receipt['sourceBefore']['inputHashes'], current['inputHashes'])
    gate.require(gate.source(ROOT) == current, 'Source changed while checking the owner exception')
    return {'type': 'pos-owner-repeat-verification-waiver', 'status': 'NOT_RUN_OWNER_WAIVER',
            'candidateSourceSha': sha, 'releaseSourceSha': current['sha'],
            'candidateVerificationStatus': 'PASS', 'applicationInputsVerified': True,
            'changedReleaseSupportPaths': changed,
            'candidateReceiptSha256': hashlib.sha256((evidence / 'receipt.json').read_bytes()).hexdigest(),
            'candidateEvidence': str(evidence), 'reason': 'Owner explicitly requested stopping repeated verification and deploying.'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--evidence', required=True)
    parser.add_argument('--record', required=True)
    args = parser.parse_args()
    try:
        result = verify(args.evidence)
        Path(args.record).write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result, sort_keys=True))
    except (gate.InvalidEvidence, OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        raise SystemExit('OWNER_CANDIDATE_REUSE_BLOCKED: ' + str(error))
