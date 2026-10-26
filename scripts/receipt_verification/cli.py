#!/usr/bin/env python3
"""Offline metadata verification; no signing and no configurable trust-root path."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
from verify import MAX_POLICY,MAX_RECEIPT,MAX_STATEMENT,NotConfigured,Rejected,json_bytes,read_file,verify,digest

ROOT=Path(__file__).resolve().parents[2]

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ['statement','signature','receipt','head-sha','base-sha']:
        parser.add_argument('--'+name,required=True)
    parser.add_argument('--pull-request',type=int,required=True)
    args=parser.parse_args()
    try:
        policy_bytes=read_file(ROOT/'scripts/receipt_verification/trust-policy.json',MAX_POLICY)
        policy=json_bytes(policy_bytes,MAX_POLICY)
        recipe=json_bytes(read_file(ROOT/'scripts/local_verification/recipe.json',MAX_POLICY),MAX_POLICY)
        result=verify(read_file(args.statement,MAX_STATEMENT),read_file(args.signature,64),
            read_file(args.receipt,MAX_RECEIPT),policy,recipe,{'repository':'ahc0403-commits/globospossystem',
                'headSha':args.head_sha,'baseSha':args.base_sha,'pullRequest':args.pull_request,'policyFileSha256':digest(policy_bytes)})
        print('POS_LOCAL_ATTESTATION_VERIFIED '+json.dumps(result,sort_keys=True)); return 0
    except NotConfigured as error:
        print('POS_LOCAL_ATTESTATION_NOT_CONFIGURED: '+str(error),file=sys.stderr); return 3
    except (Rejected,ValueError,KeyError,TypeError,OSError,subprocess.SubprocessError) as error:
        print('POS_LOCAL_ATTESTATION_REJECTED: '+str(error),file=sys.stderr); return 1

if __name__=='__main__':
    sys.exit(main())
