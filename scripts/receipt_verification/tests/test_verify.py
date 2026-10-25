import base64
import copy
import datetime as dt
import hashlib
import json
import shlex
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HERE=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(HERE))
import verify as gate
import github_readonly as github


def raw(value): return (json.dumps(value,sort_keys=True,separators=(',',':'))+'\n').encode()


class FixtureBase:
    @classmethod
    def setUpClass(cls):
        # Disposable synthetic test material only. No key is added to policy,
        # GitHub, an agent, keychain, account, device or external service.
        cls.area=tempfile.TemporaryDirectory(prefix='pos-test-key-no-authority-')
        cls.key=Path(cls.area.name)/'fixture.pem'
        subprocess.run(['openssl','genpkey','-algorithm','ED25519','-out',str(cls.key)],check=True,capture_output=True)
        cls.der=subprocess.check_output(['openssl','pkey','-in',str(cls.key),'-pubout','-outform','DER'])
        cls.fingerprint=gate.digest(cls.der)

    @classmethod
    def tearDownClass(cls): cls.area.cleanup()

    def setUp(self):
        self.now=dt.datetime.now(dt.timezone.utc)
        self.start=(self.now-dt.timedelta(seconds=20)).isoformat()
        self.end=(self.now-dt.timedelta(seconds=10)).isoformat()
        self.expected={'repository':github.REPO,'headSha':'a'*40,'baseSha':'b'*40,'pullRequest':7}
        self.recipe=json.loads((HERE.parent/'local_verification/recipe.json').read_text())
        hashes={'scripts/check_repo.sh':'1'*64,'test/required.dart':'2'*64,'lib/example.dart':'3'*64}
        source={'sha':'a'*40,'treeSha':'c'*40,'inputHashes':hashes,
                'fingerprint':gate.digest(json.dumps(hashes,sort_keys=True).encode())}
        self.value={'schemaVersion':1,'type':'pos-local-verification','kind':'candidate','completed':True,
                    'status':'PASS','sourceBefore':source,'sourceAfter':copy.deepcopy(source),
                    'startedAt':self.start,'finishedAt':self.end,'contractSha256':'d'*64,'runId':'e'*32,'steps':[]}
        for step in self.recipe['steps']:
            counts={'passed':1,'failed':0,'skipped':0}
            if step['format'] in {'flutter','deno'}: counts['completedSuites']=1
            if step['format']=='repository':
                counts.update({'completedSuites':3,'repositoryStages':66,'reexecutedWithSqlFixture':95,
                    'skipped':98,'notApplicableOnLinux':sorted(gate.NATIVE),
                    'unavailableOptionalCrossRepository':sorted(gate.OPTIONAL),
                    'deno':{'passed':80,'failed':0,'skipped':0,'completedSuites':9},
                    'node':{'passed':9,'failed':0,'skipped':0}})
            self.value['steps'].append({'id':step['id'],'argv':step['argv'],
                'commandSha256':gate.digest(json.dumps(step['argv']).encode()),'command':shlex.join(step['argv']),'log':step['id']+'.log','exitCode':0,
                'sourceSha':'a'*40,'startedAt':self.start,'finishedAt':self.start,
                'durationMs':0,'logSha256':'f'*64,'counts':counts})
        for key in ['imageBuild','toolProbe']: self.value[key]={'exitCode':0,'logSha256':'f'*64}
        self.value['environment']={'linux':dict(self.recipe['tools'],osId='ubuntu',osVersion='24.04',arch='x86_64'),
            'image':{'Os':'linux','Architecture':'amd64','Id':'sha256:'+'9'*64},
            'fixtureImages':[{'Os':'linux','Architecture':'arm64','Id':'sha256:'+'8'*64}]}
        self.value['artifacts']=[{'path':p,'bytes':10,'sha256':'f'*64} for p in
            ['artifacts/web/index.html','artifacts/web/main.dart.js','artifacts/web/flutter_bootstrap.js',
             'artifacts/web/photo_import_worker.js','nested/fixture-images.jsonl']]
        self.policy={'schemaVersion':1,'enabled':True,'repository':github.REPO,'independentCustodyApproved':True,
            'protectedWorkflowApproved':True,'maxAgeSeconds':21600,'contractSha256':'d'*64,
            'protectedInputsSha256':gate.protected_digest(hashes),'repositoryStages':66,
            'minimumAssertions':{s['id']:1 for s in self.recipe['steps']},
            'trustedExecutors':[{'fingerprintSha256':self.fingerprint,
                                'publicKeySpkiDerBase64':base64.b64encode(self.der).decode()}]}
        self.policy_hash=gate.digest(raw(self.policy))
        self.expected['policyFileSha256']=self.policy_hash
        for item in [self.value['sourceBefore'],self.value['sourceAfter']]:
            item['inputHashes'][gate.POLICY_PATH]=self.policy_hash
            item['fingerprint']=gate.digest(json.dumps(item['inputHashes'],sort_keys=True).encode())
        self.statement={'_type':gate.STATEMENT_TYPE,**self.expected,'runId':'e'*32,
            'verifiedAt':self.end,'executorFingerprintSha256':self.fingerprint}
        self.statement['pullRequest']=self.statement.pop('pullRequest')

    def signed(self,value=None,statement=None,domain=gate.DOMAIN):
        receipt=raw(self.value if value is None else value)
        claim=copy.deepcopy(self.statement if statement is None else statement)
        claim['receiptSha256']=gate.digest(receipt)
        payload=raw(claim)
        with tempfile.TemporaryDirectory() as area:
            message=Path(area)/'message'; message.write_bytes(domain+payload)
            signature=subprocess.check_output(['openssl','pkeyutl','-sign','-inkey',str(self.key),'-rawin','-in',str(message)])
        return payload,signature,receipt

    def check(self,parts=None,policy=None):
        return gate.verify(*(parts or self.signed()),self.policy if policy is None else policy,
                           self.recipe,self.expected,now=self.now)


class ReceiptTests(FixtureBase, unittest.TestCase):
    def test_real_ed25519_positive_fixture(self):
        self.assertEqual(self.check()['verifiedHeadSha'],'a'*40)

    def test_disabled_policy_rejects_before_submitted_data(self):
        for change in [{'enabled':False},{'trustedExecutors':[]}]:
            p=dict(self.policy,**change)
            with self.subTest(change=change),self.assertRaises(gate.NotConfigured):
                self.check((b'not JSON',b'',b''),p)

    def test_approval_booleans_do_not_prove_independence_but_missing_approval_blocks(self):
        for key in ['independentCustodyApproved','protectedWorkflowApproved']:
            with self.subTest(key=key),self.assertRaises(gate.Rejected): self.check(policy=dict(self.policy,**{key:False}))

    def test_submitter_key_is_not_an_approved_executor(self):
        claim=dict(self.statement,executorFingerprintSha256='0'*64)
        with self.assertRaisesRegex(gate.Rejected,'Unapproved executor'): self.check(self.signed(statement=claim))

    def test_bad_signature_or_different_signing_purpose_rejects(self):
        parts=self.signed()
        for bad in [(parts[0],b'\x00'*64,parts[2]),(parts[0],parts[1][:-1],parts[2]),
                    self.signed(domain=b'git-commit\x00')]:
            with self.subTest(bad=bad[1][:8]),self.assertRaises(gate.Rejected): self.check(bad)

    def test_statement_mutation_rejects_even_if_json_remains_valid(self):
        p,s,r=self.signed(); claim=json.loads(p); claim['verifiedAt']=self.start
        with self.assertRaisesRegex(gate.Rejected,'signature'): self.check((raw(claim),s,r))

    def test_receipt_mutation_without_new_signature_rejects(self):
        p,s,r=self.signed()
        with self.assertRaisesRegex(gate.Rejected,'altered'): self.check((p,s,r+b' '))

    def test_signed_wrong_repository_sha_base_pr_instance_purpose_rejects(self):
        for key,value in [('repository','other/repo'),('headSha','0'*40),('baseSha','0'*40),
                          ('pullRequest',8),('runId','0'*32),('_type','other-protocol')]:
            claim=dict(self.statement,**{key:value})
            with self.subTest(key=key),self.assertRaises(gate.Rejected): self.check(self.signed(statement=claim))

    def test_signed_failed_partial_missing_or_changed_steps_reject(self):
        for change in ['failed','incomplete','missing','extra','reorder','argv','digest','exit','boolean-exit','step-sha','duration','missing-log','missing-log-path','executed-command']:
            v=copy.deepcopy(self.value)
            if change=='failed': v['status']='FAIL'
            elif change=='incomplete': v['completed']=False
            elif change=='missing': v['steps'].pop()
            elif change=='extra': v['steps'].append(copy.deepcopy(v['steps'][0]))
            elif change=='reorder': v['steps'].reverse()
            elif change=='argv': v['steps'][0]['argv']=['true']
            elif change=='digest': v['steps'][0]['commandSha256']='0'*64
            elif change=='exit': v['steps'][0]['exitCode']=1
            elif change=='boolean-exit': v['steps'][0]['exitCode']=False
            elif change=='step-sha': v['steps'][0]['sourceSha']='0'*40
            elif change=='duration': v['steps'][0]['durationMs']=999999999
            elif change=='missing-log-path': v['steps'][0].pop('log')
            elif change=='executed-command': v['steps'][0]['command']='true'
            else: v['steps'][0].pop('logSha256')
            with self.subTest(change=change),self.assertRaises(gate.Rejected): self.check(self.signed(v))

    def test_skipped_empty_failed_or_missing_security_suites_reject(self):
        repo=next(i for i,s in enumerate(self.value['steps']) if s['id']=='repository')
        for change in ['empty','failed','skip','unknown-exclusion','missing-native','missing-deno','missing-node']:
            v=copy.deepcopy(self.value); c=v['steps'][repo]['counts']
            if change=='empty': c['passed']=0
            elif change=='failed': c['failed']=1
            elif change=='skip': c['skipped']+=1
            elif change=='unknown-exclusion': c['unavailableOptionalCrossRepository']=['arbitrary skip']
            elif change=='missing-native': c['notApplicableOnLinux']=[]
            elif change=='missing-deno': c['deno']['completedSuites']=8
            else: c['node']['passed']=0
            with self.subTest(change=change),self.assertRaises(gate.Rejected): self.check(self.signed(v))

    def test_required_test_removal_cannot_be_hidden_by_recomputed_hashes_and_signature(self):
        v=copy.deepcopy(self.value)
        for source in [v['sourceBefore'],v['sourceAfter']]:
            del source['inputHashes']['test/required.dart']
            source['fingerprint']=gate.digest(json.dumps(source['inputHashes'],sort_keys=True).encode())
        with self.assertRaisesRegex(gate.Rejected,'separate policy review'): self.check(self.signed(v))

    def test_candidate_cannot_replace_trusted_public_key_policy(self):
        value=copy.deepcopy(self.value)
        for item in [value['sourceBefore'],value['sourceAfter']]:
            item['inputHashes'][gate.POLICY_PATH]='0'*64
            item['fingerprint']=gate.digest(json.dumps(item['inputHashes'],sort_keys=True).encode())
        with self.assertRaisesRegex(gate.Rejected,'trusted policy'): self.check(self.signed(value))

    def test_unapproved_runner_changed_source_and_false_fingerprint_reject(self):
        for change in ['runner','after','fingerprint','traversal']:
            v=copy.deepcopy(self.value)
            if change=='runner': v['contractSha256']='0'*64
            elif change=='after': v['sourceAfter']['sha']='0'*40
            elif change=='fingerprint': v['sourceBefore']['fingerprint']=v['sourceAfter']['fingerprint']='0'*64
            else:
                for source in [v['sourceBefore'],v['sourceAfter']]: source['inputHashes']['../escape']='0'*64
            with self.subTest(change=change),self.assertRaises(gate.Rejected): self.check(self.signed(v))

    def test_old_future_naive_or_non_utc_times_reject(self):
        for date in ['2020-01-01T00:00:00+00:00',(self.now+dt.timedelta(hours=1)).isoformat(),
                     self.now.replace(tzinfo=None).isoformat(),'2026-10-24T07:00:00+07:00']:
            v=copy.deepcopy(self.value); v['finishedAt']=date
            with self.subTest(date=date),self.assertRaises(gate.Rejected): self.check(self.signed(v))

    def test_wrong_os_tool_bootstrap_or_missing_artifacts_reject(self):
        for change in ['os','arch','flutter','bootstrap','artifact','duplicate','traversal']:
            v=copy.deepcopy(self.value)
            if change=='os': v['environment']['linux']['osId']='darwin'
            elif change=='arch': v['environment']['linux']['arch']='arm64'
            elif change=='flutter': v['environment']['linux']['flutter']='wrong'
            elif change=='bootstrap': v['imageBuild']['exitCode']=1
            elif change=='artifact': v['artifacts'].pop()
            elif change=='duplicate': v['artifacts'].append(copy.deepcopy(v['artifacts'][0]))
            else: v['artifacts'][0]['path']='../escape'
            with self.subTest(change=change),self.assertRaises(gate.Rejected): self.check(self.signed(v))

    def test_duplicate_keys_nonfinite_json_and_size_limits_reject(self):
        for data in [b'{"status":"FAIL","status":"PASS"}',b'{"duration":NaN}',b'\xff',b' '* (gate.MAX_STATEMENT+1)]:
            with self.subTest(data=data[:50]),self.assertRaises(gate.Rejected): gate.json_bytes(data,gate.MAX_STATEMENT)

    def test_signature_public_key_type_and_fingerprint_are_pinned(self):
        for value in ['invalid','ZmFrZQ==']:
            p=copy.deepcopy(self.policy); p['trustedExecutors'][0]['publicKeySpkiDerBase64']=value
            with self.subTest(value=value),self.assertRaises(gate.Rejected): self.check(policy=p)
        p=copy.deepcopy(self.policy); p['trustedExecutors'][0]['fingerprintSha256']='0'*64
        with self.assertRaises(gate.Rejected): self.check(policy=p)

    def test_actual_cli_has_no_trust_override_and_default_never_passes(self):
        with tempfile.TemporaryDirectory() as area:
            p,s,r=self.signed(); path=Path(area)
            for name,data in [('statement',p),('signature',s),('receipt',r)]: (path/name).write_bytes(data)
            command=[sys.executable,'-B',str(HERE/'cli.py'),'--statement',str(path/'statement'),
                '--signature',str(path/'signature'),'--receipt',str(path/'receipt'),
                '--head-sha','a'*40,'--base-sha','b'*40,'--pull-request','7']
            result=subprocess.run(command,capture_output=True,text=True)
            self.assertEqual(result.returncode,3,result.stderr)
            self.assertIn('NOT_CONFIGURED',result.stderr)
            result=subprocess.run(command+['--trust-policy','attacker.json'],capture_output=True,text=True)
            self.assertEqual(result.returncode,2)

    def test_approved_minimum_counts_and_stage_count_cannot_be_omitted(self):
        p=copy.deepcopy(self.policy); p['minimumAssertions'][self.recipe['steps'][0]['id']]=2
        with self.assertRaisesRegex(gate.Rejected,'minimum'): self.check(policy=p)
        p=copy.deepcopy(self.policy); p['repositoryStages']=67
        with self.assertRaisesRegex(gate.Rejected,'repository stages'): self.check(policy=p)

    def test_tool_and_fixture_image_identity_missing_rejects(self):
        for key in ['image','fixtureImages']:
            v=copy.deepcopy(self.value); del v['environment'][key]
            with self.subTest(key=key),self.assertRaises(gate.Rejected): self.check(self.signed(v))

    def test_missing_or_symlink_evidence_rejects(self):
        with tempfile.TemporaryDirectory() as area:
            path=Path(area); (path/'file').write_bytes(b'{}'); (path/'link').symlink_to(path/'file')
            for p in [path/'absent',path/'link']:
                with self.subTest(path=p),self.assertRaises(gate.Rejected): gate.read_file(p,100)

    def test_workflow_proposal_runs_only_trusted_metadata_verifier(self):
        root=HERE.parents[1]
        text=(root/'docs/pos/local-verification/proposals/pos_release_contract.yml.example').read_text()
        self.assertIn('pull_request_target:',text)
        self.assertIn('name: POS release contract',text)
        self.assertIn('ref: ${{ github.sha }}',text)
        self.assertIn('persist-credentials: false',text)
        self.assertNotIn('checks: write',text); self.assertNotIn('id-token: write',text)
        self.assertNotIn('continue-on-error:',text)
        runs=[line.strip() for line in text.splitlines() if line.lstrip().startswith('run:')]
        self.assertEqual(runs,['run: python3 -B scripts/receipt_verification/github_readonly.py'])
        self.assertFalse(list((root/'.github/workflows').glob('*.yml')))
        policy=json.loads((root/'docs/pos/local-verification/proposals/actions-event-policy.json').read_text())
        self.assertEqual(policy['conditions']['workflow_path'],{'include':['~ALL'],'exclude':[]})
        self.assertEqual(policy['rules'],[{'type':'restrict_action_events','parameters':{'allowed_events':['pull_request_target']}}])


class Reader:
    def __init__(self,items): self.items=list(items); self.calls=0; self.bytes=0; self.paths=[]
    def get(self,path,maximum,raw=False):
        self.calls+=1; self.paths.append((path,raw)); data=self.items.pop(0)
        if len(data)>maximum: raise gate.Rejected('oversized response')
        self.bytes+=len(data); return data


class TransportTests(FixtureBase, unittest.TestCase):
    # Shares only disposable fixture setup; no duplicate receipt test execution.
    def event(self):
        pr={'number':7,'state':'open','head':{'sha':'a'*40},
            'base':{'sha':'b'*40,'ref':'main','repo':{'full_name':github.REPO}}}
        return {'number':7,'repository':{'full_name':github.REPO},'pull_request':pr}

    def test_complete_fetch_is_five_bounded_gets_not_test_execution(self):
        event=self.event(); p,s,r=self.signed(); reader=Reader([raw(event['pull_request']),p,s,r,raw(event['pull_request'])])
        result=github.verify_event(event,'pull_request_target',self.policy,self.recipe,reader,self.policy_hash)
        self.assertEqual(result['apiRequests'],5)
        self.assertEqual([x[1] for x in reader.paths],[False,True,True,True,False])
        self.assertTrue(all(x[0].startswith('/repos/'+github.REPO+'/') for x in reader.paths))

    def test_disabled_policy_makes_no_network_calls(self):
        reader=Reader([])
        with self.assertRaises(gate.NotConfigured):
            github.verify_event({},'pull_request_target',dict(self.policy,enabled=False),self.recipe,reader,self.policy_hash)
        self.assertEqual(reader.calls,0)

    def test_head_change_during_fetch_or_stale_event_cannot_pass(self):
        event=self.event(); p,s,r=self.signed(); changed=copy.deepcopy(event['pull_request']); changed['head']['sha']='0'*40
        for items in [[raw(changed)],[raw(event['pull_request']),p,s,r,raw(changed)]]:
            reader=Reader(items)
            with self.subTest(items=len(items)),self.assertRaisesRegex(gate.Rejected,'stale|PR changed'):
                github.verify_event(event,'pull_request_target',self.policy,self.recipe,reader,self.policy_hash)

    def test_wrong_trigger_closed_pr_wrong_target_and_missing_evidence_reject(self):
        event=self.event()
        with self.assertRaises(gate.Rejected): github.verify_event(event,'workflow_dispatch',self.policy,self.recipe,Reader([]),self.policy_hash)
        for change in ['closed','repo','base']:
            pr=copy.deepcopy(event['pull_request'])
            if change=='closed': pr['state']='closed'
            elif change=='repo': pr['base']['repo']['full_name']='other/repo'
            else: pr['base']['ref']='other'
            with self.subTest(change=change),self.assertRaises(gate.Rejected): github.context(pr,7)
        reader=Reader([raw(event['pull_request']),b'{}',b'0'*64,b'{}'])
        with self.assertRaises(gate.Rejected): github.verify_event(event,'pull_request_target',self.policy,self.recipe,reader,self.policy_hash)

    def test_redirects_external_targets_and_request_budget_are_denied(self):
        with self.assertRaises(gate.Rejected): github.NoRedirect().redirect_request(None,None,302,'',{},'https://evil.invalid')
        client=github.GitHubReadOnly('fixture-not-real')
        with self.assertRaises(gate.Rejected): client.get('https://evil.invalid',100)
        client.calls=5
        with self.assertRaises(gate.Rejected): client.get('/repos/'+github.REPO+'/pulls/7',100)

    def test_actual_github_entrypoint_default_exits_three_before_network(self):
        result=subprocess.run([sys.executable,'-B',str(HERE/'github_readonly.py')],capture_output=True,text=True,env={})
        self.assertEqual(result.returncode,3,result.stderr)
        self.assertNotIn('VERIFIED',result.stdout)
