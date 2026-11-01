"""Actual new-store kitchen identity -> native DB broadcast -> real WebSocket.

This proves software transport/authorization, not physical opening acceptance
or an actual order's kitchen/tray/floor completion workflow.
"""
import secrets


def run(platform,registered,dart):
    from owned_platform import private_json
    from realtime_probe import run as realtime
    store,other=registered['stores']
    kitchen=next(a for a in registered['accounts'] if a['storeId']==store and a['role']=='kitchen')
    def call(path,body,token=None):
        status,value=platform.request('pos',path,body,token=token)
        if status!=200:
            private_json(platform.output/'kds-realtime-scenario-failure.json',{'path':path,'status':status,'body':value})
            raise RuntimeError('Actual KDS account API failed')
        return value
    original=call('/auth/v1/token?grant_type=password',{'email':kitchen['email'],'password':kitchen['password']})
    password='Fixture-Aa9!'+secrets.token_urlsafe(24);platform.redactions.append(password)
    value=call('/functions/v1/complete-initial-password-change',{'new_password':password},original['access_token'])
    platform.check(value.get('password_changed') is True,'actual-new-store-kitchen-completes-initial-password-gate')
    fresh=call('/auth/v1/token?grant_type=password',{'email':kitchen['email'],'password':password})
    platform.redactions.extend([fresh['access_token'],fresh['refresh_token']]);kitchen['password']=password
    private_json(platform.output/'generated-pos-accounts.private.json',registered['accounts'])
    realtime(platform,{'pos':{'session':fresh}},dart,scoped={'pos':{'allowedStore':store,'otherStore':other}})
    platform.result['newStoreKdsRealtime']={'nativeAccountWorkerAndInitialPassword':True,
      'nativeSqlBroadcastDelivered':True,'ownStoreKitchenReadAllowed':True,'otherStoreDenied':True,
      'actualOrderHandoffExercised':False,'physicalOpeningAccepted':False,'productionModified':False}
    platform.save()
