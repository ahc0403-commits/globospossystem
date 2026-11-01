"""Real two-project local Auth/REST readiness; no production access or soak claim."""
import argparse
from pathlib import Path
import signal
import sys

from owned_platform import OwnedPlatform


def probe(platform):
    identities = {}
    accounts = {}
    for project in platform.selected_projects:
        config = platform.projects[project]
        status,user = platform.request(project,'/auth/v1/admin/users',{
          'email':'runtime-admin-' + project + '@fixture.invalid',
          'password':config['password'], 'email_confirm':True},token=config['service'],key=config['service'])
        platform.check(status in (200,201) and bool(user.get('id')), project + '-real-auth-api-user')
        status,session = platform.request(project,'/auth/v1/token?grant_type=password',{
          'email':user['email'], 'password':config['password']})
        platform.check(status==200 and session.get('user',{}).get('id')==user['id'],project + '-real-password-login')
        status,current = platform.request(project,'/auth/v1/user',token=session['access_token'])
        platform.check(status==200 and current.get('id')==user['id'],project + '-jwt-current-user')
        status,refreshed = platform.request(project,'/auth/v1/token?grant_type=refresh_token',{'refresh_token':session['refresh_token']})
        platform.check(status==200 and refreshed.get('user',{}).get('id')==user['id'],project + '-real-token-refresh')
        platform.check(platform.sql(project,'SELECT count(*) FROM auth.users;').stdout.strip()=='1',project + '-only-synthetic-user')
        status,_ = platform.request(project,'/rest/v1/',headers={'Accept-Profile':'pos_command_private' if project=='pos' else 'private'})
        platform.check(status==406,project + '-private-schema-not-exposed')
        identities[project] = user['id']
        accounts[project] = {'user':user, 'session':refreshed}
        platform.redactions.extend([refreshed['access_token'],refreshed['refresh_token']])
    if set(platform.selected_projects)=={'pos','office'}:
        platform.check(identities['pos'] != identities['office'],'independent-auth-identities')
        status,_ = platform.request('office','/auth/v1/user',key=platform.projects['pos']['anon'])
        platform.check(status==401,'cross-project-api-key-rejected')
    if 'pos' in platform.selected_projects:
        status,_ = platform.request('pos','/rest/v1/rpc/begin_office_legal_connection_v1',{
          'p_operation_id':'70000000-0000-4000-8000-000000000001',
          'p_tax_entity_id':'70000000-0000-4000-8000-000000000002','p_proof':'fixture-proof-012345678901234567890123456789'})
        platform.check(status in (401,403),'real-rest-anonymous-function-acl-rejected')
    return accounts


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--snapshot-dir',required=True,type=Path)
    parser.add_argument('--office-root',required=True,type=Path)
    parser.add_argument('--output',required=True,type=Path)
    parser.add_argument('--projects',choices=['both','pos','office'],default='both')
    parser.add_argument('--exercise-legal-connection',action='store_true')
    parser.add_argument('--exercise-stores',action='store_true')
    parser.add_argument('--exercise-storage',action='store_true')
    parser.add_argument('--storage-reference',type=Path)
    parser.add_argument('--deno',type=Path)
    parser.add_argument('--deno-cache',type=Path)
    args=parser.parse_args()
    if args.exercise_stores:
        args.exercise_legal_connection=True
    if args.exercise_legal_connection and args.projects!='both':
        parser.error('Cross-project legal/store workflows require both independent projects')
    if args.exercise_storage and args.projects=='office':
        parser.error('This Storage probe currently selects POS only')
    if args.exercise_legal_connection and (args.deno is None or args.deno_cache is None):
        parser.error('Actual Office Edge requires explicit Deno executable and cache')
    if args.exercise_storage and args.storage_reference is None:
        parser.error('Actual Storage needs the private source-bound migration reference')
    signal.signal(signal.SIGTERM,lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    selected=('pos','office') if args.projects=='both' else (args.projects,)
    platform=OwnedPlatform(args.snapshot_dir,args.office_root,args.output,projects=selected)
    try:
        with platform.runner.fixture_locks(args.snapshot_dir,list(selected)):
            if args.exercise_storage:
                from storage_runtime import preflight
                preflight(platform,'pos',args.storage_reference)
            platform.start()
            accounts=probe(platform)
            if args.exercise_storage:
                from storage_runtime import start
                start(platform,'pos',args.storage_reference)
                from storage_probe import run as storage_probe
                storage_probe(platform)
            if args.exercise_legal_connection:
                platform.start_office_edge(args.deno,args.deno_cache)
                from legal_http_scenario import run
                legal=run(platform,accounts)
                if args.exercise_stores:
                    platform.start_edge('pos','store-account-onboarding',args.deno,args.deno_cache)
                    from store_http_scenario import run as stores
                    stores(platform,accounts,legal)
            platform.validate_inputs()
            platform.result['status']='PASS'
    except BaseException as error:
        platform.result['status']='FAIL'
        platform.result['failureType']=type(error).__name__
        # Messages may come from transport libraries; retain them only privately.
        platform.result['failure']=str(error)
        raise
    finally:
        platform.close()
        print('PLATFORM_RESULT='+str(platform.result['status'])+
          ';checks='+str(len(platform.result['checks']))+
          ';cleanup='+str(platform.result.get('cleanupVerified')),flush=True)
    return 0 if platform.result['status']=='PASS' else 1


if __name__=='__main__':
    sys.exit(main())
