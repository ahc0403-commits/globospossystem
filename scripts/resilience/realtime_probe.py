"""Execute actual SDK WebSocket code against only this owned native runtime."""
import hashlib
import json
import os
from pathlib import Path


def preflight(platform,dart):
    dart=Path(dart)
    platform.schema.require(dart.is_absolute() and os.access(dart,os.X_OK),'Explicit existing Dart SDK required')
    platform.command('realtime-dart-sdk',[str(dart),'--version'])


def run(platform,accounts,dart,scoped=None):
    from owned_platform import private_json
    source=Path(__file__).with_suffix('.dart')
    prefix='realtime-scoped' if scoped else 'realtime-basic'
    input_path=platform.output/(prefix+'.private.json')
    private_json(input_path,{'kind':'owned-realtime-websocket-probe','runId':platform.run_id,'evidencePrefix':prefix,'projects':[
      {'project':name,'tenant':p['realtimeTenant'],'origin':p['realtimeOrigin'],
       'gatewayOrigin':p['url'],
       'anon':p['anon'],'userToken':accounts[name]['session']['access_token'],
       **({'service':p['service'],'dbContainer':p['db'],'dbPassword':p['adminPassword'],**scoped[name]} if scoped and name in scoped else {})}
      for name,p in platform.projects.items() if name in accounts]})
    platform.command('actual-'+prefix+'-websocket',[str(dart),str(source),str(input_path)],timeout=90)
    report=json.loads((platform.output/(prefix+'-result.json')).read_text())
    expected=3*len(accounts)+(4*len(scoped) if scoped else 0)
    platform.check(report.get('status')=='PASS' and report.get('runId')==platform.run_id
      and len(report.get('checks',[]))==expected, 'actual-'+prefix+'-websocket-and-rls-checks-completed')
    platform.result.setdefault('realtimeWebsocketProbes',{})[prefix]={**report,'sourceSha256':hashlib.sha256(source.read_bytes()).hexdigest()}
    for name in accounts:platform.result['realtime'][name]['websocketExerciseComplete']=True
    platform.save()
