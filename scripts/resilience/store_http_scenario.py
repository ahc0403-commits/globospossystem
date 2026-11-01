"""First/additional stores through registration, real Auth worker and Office API.

This is software setup evidence. Never sets hardware tests, password handover,
employee attendance or opening acceptance to successful without exercising them.
"""
import json
import uuid


def run(platform, accounts, legal):
    token=accounts['pos']['session']['access_token']
    def pos(name,body):
        status,result=platform.request('pos','/rest/v1/rpc/'+name,body,token=token)
        if status!=200:
            from owned_platform import private_json
            private_json(platform.output/('failed-store-rpc-'+name+'.json'),{'status':status,'body':result})
            raise RuntimeError('Real store RPC failed: '+name)
        return result
    brand=str(uuid.uuid4())
    created=pos('admin_create_brand_v2',{'p_brand_id':brand,'p_name':'Runtime first brand',
      'p_code':'RT','p_brand_master_id':'61000000-0000-4000-8000-000000000099','p_tax_entity_ids':[legal['tax']]})
    platform.check(created.get('id')==brand and legal['tax'] in created.get('tax_entity_ids',[]),
      'real-first-brand-is-explicitly-linked-to-new-legal-entity')
    stores=[];private_accounts=[]
    from owned_platform import private_json
    for index in range(2):
        request=str(uuid.uuid4());code='QA0'+str(index+1)
        config={'dine_in':True,'kitchens':1,'tray':index==1,'tablet':False,'customer_display':False,
          'fulfillment_mode':'paperless','areas':[{'code':'HALL','name':'Hall','physical_floor':None}]}
        preview=pos('admin_preview_store_registration_v1',{'p_request_id':request,
          'p_brand_id':brand,'p_code':code,'p_config':config})
        platform.check(preview.get('code')==code and isinstance(preview.get('accounts'),list)
          and 0<len(preview['accounts'])<=50,'first-store-preview' if index==0 else 'additional-store-preview')
        payload={'p_request_id':request,'p_input':{'name':'Runtime store '+str(index+1),'address':'Owned fixture',
          'code':code,'brand':brand,'entity':legal['tax'],'mode':'standard','charge':None,'config':config}}
        store=pos('admin_register_store_v1',payload)
        platform.check(isinstance(store,str) and str(uuid.UUID(store))==store,'real-store-registration-'+str(index+1))
        repeated=pos('admin_register_store_v1',payload)
        platform.check(repeated==store,'real-store-registration-original-request-replays-'+str(index+1))
        status,finished=platform.request('pos','/functions/v1/store-account-onboarding',{'job_id':request,'retry':True},token=token)
        private_json(platform.output/('store-'+str(index+1)+'-worker-response.json'),{'status':status,'body':finished})
        platform.check(status==200 and finished.get('status')=='complete','actual-edge-creates-fixed-auth-accounts-'+str(index+1))
        original=pos('admin_store_onboarding_status_v1',{'p_job_id':request})
        platform.check(original.get('status')=='complete','store-onboarding-status-is-complete-'+str(index+1))
        # Read readiness exactly as the app does. Missing physical/handover work
        # must remain blocked, rather than being seeded as PASS to open a store.
        readiness=pos('admin_get_store_opening_readiness',{'p_store_id':store})
        workforce=pos('admin_get_store_workforce_readiness',{'p_store_id':store})
        private_json(platform.output/('store-'+str(index+1)+'-readiness.json'),{'opening':readiness,'workforce':workforce})
        platform.check(isinstance(readiness,dict) and isinstance(workforce,dict),'new-store-readiness-is-available-'+str(index+1))
        for account in preview['accounts']:
            code=account['account_code'];email=code+'@globos.world'
            private_accounts.append({'storeId':store,'accountCode':code,'role':account['role'],'email':email,
              'password':platform.projects['pos']['password'],'fixtureOnly':True})
        stores.append(store)
    platform.check(len(set(stores))==2,'first-and-additional-pos-store-identities-are-distinct')
    status,linked=platform.request('office','/functions/v1/pos-bridge',{
      'action':'store_mapping_sync','storeIds':stores,'taxEntityId':legal['tax']},
      token=accounts['office']['session']['access_token'])
    private_json(platform.output/'first-additional-store-office-response.json',{'status':status,'body':linked})
    platform.check(status==200,'actual-office-edge-maps-first-and-additional-stores')
    count=platform.sql('office',"SELECT count(*) FROM ops.stores WHERE pos_store_id IN ("+
      ','.join("'"+s+"'" for s in stores)+') AND legal_entity_id=\''+legal['officeLegal']+'\';').stdout.strip()
    platform.check(count=='2','both-pos-stores-use-the-verified-office-legal-owner')
    private_json(platform.output/'generated-pos-accounts.private.json',private_accounts)
    platform.result['storeHttpScenario']={'storesCreated':2,'nativeAuthWorkerExercised':True,
      'fixedAccountRequirements':len(private_accounts),'physicalOpeningAccepted':False,
      'businessLifecycleComplete':False,'productionModified':False}
    platform.save()
    return {'brand':brand,'tax':legal['tax'],'stores':stores,'accounts':private_accounts}
