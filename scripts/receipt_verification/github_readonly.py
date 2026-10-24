#!/usr/bin/env python3
"""Read bounded metadata on GitHub; execute no submitted code and write no API state.

Only a trusted default-branch workflow may invoke this. app_id alone does not
pin this workflow, and the current disabled policy deliberately cannot pass.
"""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from verify import (MAX_POLICY,MAX_RECEIPT,MAX_STATEMENT,NotConfigured,Rejected,
                    json_bytes,policy_ready,read_file,require,verify,digest)

ROOT=Path(__file__).resolve().parents[2]
REPO='ahc0403-commits/globospossystem'
RESULT_REF='pos-local-verification-results'
EVENT_LIMIT=262144


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,req,fp,code,msg,headers,newurl):
        raise Rejected('GitHub redirect rejected')


class GitHubReadOnly:
    def __init__(self,token=''):
        self.token=token
        self.calls=0
        self.bytes=0
        self.opener=urllib.request.build_opener(NoRedirect)

    def get(self,path,maximum,raw=False):
        require(path.startswith('/repos/'+REPO+'/'), 'Unexpected GitHub API target')
        self.calls+=1
        require(self.calls<=5, 'Metadata request budget exceeded')
        headers={'User-Agent':'globos-pos-receipt-verifier-v1',
                 'Accept':'application/vnd.github.raw+json' if raw else 'application/vnd.github+json',
                 'X-GitHub-Api-Version':'2022-11-28'}
        # Public PR metadata is anonymous. contents:read is sufficient for the
        # three submission files; no new pull-request/check/status permission.
        if raw and self.token:
            headers['Authorization']='Bearer '+self.token
        try:
            with self.opener.open(urllib.request.Request('https://api.github.com'+path,headers=headers),timeout=5) as response:
                data=response.read(maximum+1)
        except urllib.error.HTTPError as error:
            raise Rejected('GitHub metadata HTTP '+str(error.code)) from None
        except urllib.error.URLError as error:
            raise Rejected('GitHub metadata unavailable') from None
        require(0 < len(data) <= maximum, 'Missing/oversized GitHub metadata')
        self.bytes+=len(data)
        return data


def context(pr,number):
    require(isinstance(pr,dict) and pr.get('number')==number and pr.get('state')=='open', 'Wrong/closed PR')
    base=pr.get('base',{})
    require(base.get('repo',{}).get('full_name')==REPO and base.get('ref')=='main', 'Wrong PR target')
    head_sha=pr.get('head',{}).get('sha'); base_sha=base.get('sha')
    require(isinstance(head_sha,str) and re.fullmatch('[0-9a-f]{40}',head_sha) and
            isinstance(base_sha,str) and re.fullmatch('[0-9a-f]{40}',base_sha), 'Missing PR SHA')
    return {'repository':REPO,'headSha':head_sha,'baseSha':base_sha,'pullRequest':number}


def verify_event(event,event_name,policy,recipe,reader,policy_sha256):
    policy_ready(policy)
    require(event_name=='pull_request_target', 'Only trusted default-branch PR events are supported')
    require(event.get('repository',{}).get('full_name')==REPO, 'Unexpected event repository')
    number=event.get('number')
    require(type(number) is int and 0 < number <= 1000000000, 'Invalid PR number')
    event_context=context(event.get('pull_request'),number)
    endpoint='/repos/'+REPO+'/pulls/'+str(number)
    expected=context(json_bytes(reader.get(endpoint,EVENT_LIMIT),EVENT_LIMIT),number)
    require(event_context==expected, 'Event HEAD/base is stale')
    prefix='/repos/'+REPO+'/contents/local-verification/'+expected['headSha']+'/'
    query='?'+urllib.parse.urlencode({'ref':RESULT_REF})
    statement=reader.get(prefix+'statement.json'+query,MAX_STATEMENT,raw=True)
    signature=reader.get(prefix+'signature.bin'+query,64,raw=True)
    receipt=reader.get(prefix+'receipt.json'+query,MAX_RECEIPT,raw=True)
    result=verify(statement,signature,receipt,policy,recipe,dict(expected,policyFileSha256=policy_sha256))
    after=context(json_bytes(reader.get(endpoint,EVENT_LIMIT),EVENT_LIMIT),number)
    require(after==expected, 'PR changed during verification')
    result.update({'apiRequests':reader.calls,'metadataBytes':reader.bytes})
    return result


def main():
    try:
        policy_bytes=read_file(ROOT/'scripts/receipt_verification/trust-policy.json',MAX_POLICY)
        policy=json_bytes(policy_bytes,MAX_POLICY)
        policy_ready(policy)  # No network and no token access before configuration.
        event=json_bytes(read_file(os.environ['GITHUB_EVENT_PATH'],EVENT_LIMIT),EVENT_LIMIT)
        recipe=json_bytes(read_file(ROOT/'scripts/local_verification/recipe.json',MAX_POLICY),MAX_POLICY)
        result=verify_event(event,os.environ.get('GITHUB_EVENT_NAME'),policy,recipe,
                            GitHubReadOnly(os.environ.get('GITHUB_TOKEN','')),digest(policy_bytes))
        print('POS_LOCAL_ATTESTATION_VERIFIED '+json.dumps(result,sort_keys=True)); return 0
    except NotConfigured as error:
        print('POS_LOCAL_ATTESTATION_NOT_CONFIGURED: '+str(error),file=sys.stderr); return 3
    except (Rejected,ValueError,KeyError,TypeError,OSError,subprocess.SubprocessError) as error:
        print('POS_LOCAL_ATTESTATION_REJECTED: '+str(error),file=sys.stderr); return 1

if __name__=='__main__':
    sys.exit(main())
