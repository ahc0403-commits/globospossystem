"""Real newly registered store APIs: menu/table/order -> both KDS policies.

No physical printer, display or opening acceptance is simulated. Every command
uses a genuinely authenticated fixed account and the unchanged application RPC.
"""
from datetime import datetime, timedelta, timezone
from concurrent.futures import ThreadPoolExecutor
import json
import secrets
import uuid

from owned_platform import private_json
from additional_order_recovery_scenario import run as exercise_additional_recovery


def run(platform, accounts, registered):
    sessions={}
    def call(name,body,token):
        status,value=platform.request('pos','/rest/v1/rpc/'+name,body,token=token)
        if status!=200:
            private_json(platform.output/'order-handoff-failure.json',{'rpc':name,'status':status,'body':value})
            raise RuntimeError('Actual order/handoff API failed: '+name)
        return value
    def login(store,role):
        key=(store,role)
        if key in sessions:return sessions[key]
        account=next(a for a in registered['accounts'] if a['storeId']==store and
          (a['accountCode'].endswith('_tray1') if role=='tray' else
           a['role']==role and not a['accountCode'].endswith('_tray1')))
        def authenticate():
            status,value=platform.request('pos','/auth/v1/token?grant_type=password',
              {'email':account['email'],'password':account['password']})
            platform.schema.require(status==200,'Actual generated account login failed')
            platform.redactions.extend([value['access_token'],value['refresh_token']])
            return value
        session=authenticate()
        status,profiles=platform.request('pos','/rest/v1/users?select=must_change_password&auth_id=eq.'+session['user']['id'],token=session['access_token'])
        platform.schema.require(status==200 and len(profiles)==1,'Own generated profile required')
        if profiles[0]['must_change_password']:
            password='Fixture-Aa9!'+secrets.token_urlsafe(24);platform.redactions.append(password)
            status,changed=platform.request('pos','/functions/v1/complete-initial-password-change',
              {'new_password':password},token=session['access_token'])
            platform.schema.require(status==200 and changed.get('password_changed') is True,'Actual station initial password change required')
            account['password']=password;session=authenticate()
        sessions[key]=session['access_token']
        private_json(platform.output/'generated-pos-accounts.private.json',registered['accounts'])
        return sessions[key]
    def snapshot(token):return call('get_emergency_station_snapshot',{},token)
    def order_row(view,order):
        return next((r for r in view.get('orders',[]) if r.get('order_id')==order),None)
    def progress(token,item,action,event=None):
        event=event or str(uuid.uuid4())
        body={'p_item_id':item,'p_source_kind':'base','p_action':action,'p_delta':1,'p_event_id':event}
        return call('kds_record_station_progress_v3',body,token),event,body
    completed=[]
    for index,store in enumerate(registered['stores']):
        manager=login(store,'store_admin');kitchen=login(store,'kitchen');floor=login(store,'emergency_station')
        tray=login(store,'tray') if index==1 else None
        # Configured logical HALL comes from the real account-registration API.
        table=call('admin_create_table',{'p_store_id':store,'p_table_number':'A1','p_seat_count':4,'p_floor_label':'HALL'},manager)
        platform.check(table.get('restaurant_id')==store and table.get('floor_label')=='HALL','new-store-real-table-in-registered-area-'+str(index))
        category=call('admin_create_menu_category_with_group',{'p_store_id':store,
          'p_name_ko':'시험 음식','p_name_vi':'Mon thu','p_name_en':'Fixture food','p_sort_order':0,'p_analytics_group':'food'},manager)
        platform.schema.require(isinstance(category,dict) and category.get('id'),'Category RPC must return its actual row')
        menu_payload={'p_store_id':store,'p_category_id':category['id'],
          'p_name_ko':'시험 메뉴','p_name_vi':'Mon thu','p_name_en':'Fixture dish','p_paperless_name_vi':'Mon thu',
          'p_price':50000,'p_sort_order':0,'p_is_available':True,'p_tax':None,'p_invoice_sale_unit':'phan'}
        status,missing=platform.request('pos','/rest/v1/rpc/admin_create_menu_item_with_invoice',menu_payload,token=manager)
        platform.check(status==400 and missing.get('message')=='INVOICE_POLICY_REQUIRED',
          'new-store-menu-requires-explicit-invoice-policy-'+str(index))
        count=platform.sql('pos','SELECT count(*) FROM menu_items WHERE restaurant_id='+platform.schema.lit(store)+';').stdout.strip()
        platform.check(count=='0','failed-unapproved-menu-leaves-no-partial-registration-'+str(index))
        policy=call('approve_invoice_mapping_policy',{'p_store_id':store,'p_tax_entity_id':registered['tax'],
          'p_policy_version':'owned-fixture-v1','p_rules':{'category_units':{category['id']:'phan'},'menu_units':{},'combo_unit':'bo'},
          'p_source_reference':'Owned synthetic software test; not an operating invoice policy'},accounts['pos']['session']['access_token'])
        platform.check(policy.get('approved_by')==accounts['pos']['user']['id'],
          'new-store-real-super-admin-approves-synthetic-invoice-policy-'+str(index))
        menu=call('admin_create_menu_item_with_invoice',menu_payload,manager)
        platform.check(menu.get('restaurant_id')==store and float(menu['price'])==50000,'new-store-real-menu-with-authenticated-invoice-actor-'+str(index))
        activated=call('super_admin_set_fulfillment_mode',{'p_store_id':store,'p_mode':'paperless',
          'p_reason':'Owned software workflow fixture; physical acceptance remains unverified','p_request_id':str(uuid.uuid4())},accounts['pos']['session']['access_token'])
        platform.check(activated.get('mode')=='paperless','new-store-actual-paperless-session-'+str(index))
        day=datetime.now(timezone(timedelta(hours=7))).date().isoformat()
        body={'p_store_id':store,'p_table_id':table['id'],'p_items':[{'menu_item_id':menu['id'],'quantity':2}],
          'p_client_mutation_id':'handoff-'+str(uuid.uuid4()),'p_business_date':day}
        status,not_open=platform.request('pos','/rest/v1/rpc/create_order_for_business_day',body,token=manager)
        private_json(platform.output/('store-'+str(index+1)+'-opening-intake-guard.private.json'),{'status':status,'body':not_open})
        platform.check(status==400 and not_open.get('message')=='STORE_NOT_OPEN_FOR_NEW_ORDERS',
          'new-store-without-field-acceptance-cannot-take-orders-'+str(index))
        count=platform.sql('pos','SELECT count(*) FROM orders WHERE restaurant_id='+platform.schema.lit(store)+';').stdout.strip()
        platform.check(count=='0','blocked-opening-leaves-no-partial-order-'+str(index))
        # The rest is an explicitly preaccepted *software fixture*. Never call
        # the real acceptance RPC with fabricated field tests, handovers or
        # hardware checks. This is not evidence of new-store opening readiness.
        platform.sql('pos',"UPDATE store_lifecycle SET state='active',revision=revision+1,activated_source_hash='owned-software-fixture-no-field-acceptance' WHERE restaurant_id="+platform.schema.lit(store)+';')
        platform.result['softwareFixtureLifecycleSeeded']=True
        route='rest/rpc/create_order_for_business_day'
        platform.gateways['pos'].drop_next[route]=1
        lost=False
        try:platform.request('pos','/rest/v1/rpc/create_order_for_business_day',body,token=manager)
        except OSError:lost=True
        finally:platform.gateways['pos'].drop_next[route]=0
        platform.check(lost,'actual-order-commit-acknowledgement-is-physically-lost-'+str(index))
        recovered=call('get_order_create_receipts_v1',{'p_store_id':store,
          'p_client_mutation_ids':[body['p_client_mutation_id']]},manager)
        order=call('create_order_for_business_day',body,manager)
        platform.check(len(recovered)==1 and order.get('id')==recovered[0].get('order_id') and order.get('restaurant_id')==store,
          'new-store-order-original-mutation-replays-after-lost-ack-'+str(index))
        status,conflict=platform.request('pos','/rest/v1/rpc/create_order_for_business_day',
          {**body,'p_items':[{'menu_item_id':menu['id'],'quantity':3}]},token=manager)
        platform.check(status==400 and conflict.get('message')=='ORDER_CREATE_OPERATION_CONFLICT',
          'original-order-operation-cannot-change-quantity-'+str(index))
        receipts=call('get_order_create_receipts_v1',{'p_store_id':store,
          'p_client_mutation_ids':[body['p_client_mutation_id'],body['p_client_mutation_id'],'unknown-fixture-operation']},manager)
        platform.check(len(receipts)==1 and receipts[0].get('order_id')==order['id'],
          'actual-order-receipts-resolve-original-once-'+str(index))
        hidden=call('get_order_create_receipts_v1',{'p_store_id':store,
          'p_client_mutation_ids':[body['p_client_mutation_id']]},accounts['pos']['session']['access_token'])
        platform.check(hidden==[],'another-actor-cannot-read-original-order-receipt-'+str(index))
        status,invalid=platform.request('pos','/rest/v1/rpc/get_order_create_receipts_v1',
          {'p_store_id':store,'p_client_mutation_ids':['unknown']*101},token=manager)
        platform.check(status==400 and invalid.get('message')=='ORDER_CREATE_RECEIPT_BATCH_INVALID',
          'order-receipt-batch-size-is-bounded-'+str(index))
        initial=snapshot(kitchen);ticket=order_row(initial,order['id'])
        private_json(platform.output/('store-'+str(index+1)+'-kitchen-original.private.json'),initial)
        platform.check(initial.get('active') is True and ticket is not None and len(ticket.get('items',[]))==1,'actual-created-order-visible-to-new-kitchen-'+str(index))
        item=ticket['items'][0]['id']
        outside=login(registered['stores'][1-index],'emergency_station')
        status,denied=platform.request('pos','/rest/v1/rpc/kds_record_station_progress_v3',
          {'p_item_id':item,'p_source_kind':'base','p_action':'floor_served','p_delta':1,'p_event_id':str(uuid.uuid4())},token=outside)
        message=str(denied.get('message','')).lower() if isinstance(denied,dict) else ''
        private_json(platform.output/('store-'+str(index+1)+'-other-floor-denied.private.json'),{'status':status,'body':denied})
        platform.check(status in (400,401,403) and (message=='emergency_item_unavailable' or any(s in message for s in ['forbidden','permission','store','assignment'])),
          'other-store-real-floor-cannot-mutate-order-'+str(index))
        unchanged=platform.sql('pos','SELECT floor_served_quantity FROM emergency_fulfillment_items WHERE id='+platform.schema.lit(item)+';').stdout.strip()
        platform.check(unchanged=='0','real-target-exists-and-other-floor-did-not-change-it-'+str(index))
        for quantity in (1,2):
            done,event,payload=progress(kitchen,item,'kitchen_done')
            platform.check(done.get('kitchen_done_quantity')==quantity,'real-partial-kitchen-completion-'+str(index)+'-'+str(quantity))
            replay=call('kds_record_station_progress_v3',payload,kitchen)
            receipts=call('get_kds_progress_receipts_v1',{'p_store_id':store,'p_operation_ids':[event]},kitchen)
            platform.check(replay.get('deduplicated') is True and len(receipts)==1 and receipts[0].get('delta')==1,
              'real-kitchen-original-event-and-receipt-do-not-double-complete-'+str(index)+'-'+str(quantity))
            if tray:
                tray_view=snapshot(tray);tray_ticket=order_row(tray_view,order['id'])
                platform.check(tray_view.get('station_type')=='tray' and tray_ticket is not None,
                  'actual-partial-completion-reaches-new-tray-'+str(quantity))
                dispatched,_,_=progress(tray,item,'tray_dispatched')
                platform.check(dispatched.get('tray_dispatched_quantity')==quantity,'real-tray-partial-floor-dispatch-'+str(quantity))
            floor_view=snapshot(floor);floor_ticket=order_row(floor_view,order['id'])
            private_json(platform.output/('store-'+str(index+1)+'-floor-ready-'+str(quantity)+'.private.json'),floor_view)
            platform.check(floor_view.get('station_type')=='floor' and floor_view.get('floor_label')=='HALL' and floor_ticket is not None,
              'actual-partial-completion-reaches-assigned-floor-'+str(index)+'-'+str(quantity))
            served,_,_=progress(floor,item,'floor_served')
            platform.check(served.get('floor_served_quantity')==quantity,'actual-assigned-floor-serves-exact-partial-quantity-'+str(index)+'-'+str(quantity))
        state=json.loads(platform.sql('pos',"SELECT jsonb_build_object('kitchen',i.kitchen_done_quantity,'served',i.floor_served_quantity,'items',(SELECT count(*) FROM order_items WHERE order_id=i.order_id),'value',(SELECT sum(quantity*unit_price) FROM order_items WHERE order_id=i.order_id),'payments',(SELECT count(*) FROM payments WHERE order_id=i.order_id)) FROM emergency_fulfillment_items i WHERE i.id="+platform.schema.lit(item)+';').stdout)
        platform.check(state=={'kitchen':2,'served':2,'items':1,'value':100000,'payments':0},'new-store-handoff-preserves-original-unpaid-financial-lines-'+str(index))
        second_table=call('admin_create_table',{'p_store_id':store,'p_table_number':'A2','p_seat_count':4,'p_floor_label':'HALL'},manager)
        parallel={**body,'p_table_id':second_table['id'],'p_client_mutation_id':'parallel-'+str(uuid.uuid4())}
        with ThreadPoolExecutor(max_workers=2) as pool:
            simultaneous=list(pool.map(lambda _:call('create_order_for_business_day',parallel,manager),range(2)))
        count=platform.sql('pos','SELECT count(*) FROM orders WHERE table_id='+platform.schema.lit(second_table['id'])+';').stdout.strip()
        platform.check(simultaneous[0]['id']==simultaneous[1]['id'] and count=='1',
          'concurrent-original-order-intent-creates-one-native-order-'+str(index))
        exercise_additional_recovery(platform,store=store,order=simultaneous[0]['id'],menu=menu['id'],manager=manager,other_actor=accounts['pos']['session']['access_token'])
        completed.append({'store':store,'order':order['id'],'item':item,'state':state,'workflow':'kitchen_tray_floor' if tray else 'kitchen_floor'})
    private_json(platform.output/'new-store-order-handoff.private.json',completed)
    platform.result['newStoreOrderHandoff']={'stores':len(completed),'actualAuthApiAndNativeSql':True,
      'policies':['kitchen_floor','kitchen_tray_floor'],'originalOrderMutationReplayed':True,
      'partialQuantityAndEventReplayChecked':True,'crossStoreMutationDenied':True,
      'actualOrderAcknowledgementLost':True,'concurrentOriginalOrderCreatedOnce':True,
      'invoicePolicyPreconditionExercised':True,
      'openingWithoutAcceptanceWasRejected':True,'acceptedLifecycleSeededForSoftwareOnly':True,
      'browserOrPhysicalDisplayExercised':False,'physicalOpeningAccepted':False,
      'wholeBusinessLifecycleComplete':False,'productionModified':False}
    platform.save()
