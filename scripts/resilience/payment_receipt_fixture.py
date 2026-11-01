"""Exercise additive receipts against native financial functions in an owned DB.

Called only by the private schema rehearsal after its synthetic stock scenario.
No remote database URL, credentials, production rows or external provider calls.
"""
from concurrent.futures import ThreadPoolExecutor
import json
import hashlib
from pathlib import Path
import time

STORE='8bc9eef5-dcd5-46b1-b931-23f77132322c'
ACTOR='92000000-0000-4000-8000-000000000011'
OTHER='92000000-0000-4000-8000-000000000012'
OUTSIDE='92000000-0000-4000-8000-000000000013'
PARTIAL='95000000-0000-4000-8000-000000000010'
FULL='95000000-0000-4000-8000-000000000020'
RACE='95000000-0000-4000-8000-000000000030'
OP='96000000-0000-4000-8000-000000000010'
FULL_OP='96000000-0000-4000-8000-000000000020'
RACE_OP='96000000-0000-4000-8000-000000000030'


def run(sql):
    checks=[]
    def check(condition,name):
        if not condition:raise RuntimeError('Payment receipt fixture failed: '+name)
        checks.append(name)
    def call(body,actor=ACTOR,check_result=True):
        return sql("BEGIN;SET LOCAL ROLE authenticated;SET LOCAL request.jwt.claim.role='authenticated';SET LOCAL request.jwt.claim.sub='"+actor+"';"+body+'COMMIT;',check=check_result)
    def once(operation=OP,order=PARTIAL,amount=8000,method='CASH'):
        return "SELECT public.process_payment_once_v1('"+operation+"','"+order+"','"+STORE+"',"+str(amount)+",'"+method+"');"
    def receipts(ids,actor=ACTOR,store=STORE):
        raw=call("SELECT public.get_payment_command_receipts_v1('"+store+"',ARRAY["+
                 ','.join("'"+i+"'" for i in ids)+"]::uuid[]);",actor)
        return json.loads(raw.stdout.strip())
    sql("""
BEGIN;
INSERT INTO auth.users(id,email,instance_id,aud,role,email_confirmed_at)
SELECT ('92000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,
 'payment-receipt-'||n||'@internal.invalid','00000000-0000-0000-0000-000000000000',
 'authenticated','authenticated',now() FROM generate_series(11,13)n;
INSERT INTO public.users(id,auth_id,restaurant_id,role,full_name,is_active)
SELECT ('93000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,
 ('92000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,
 CASE WHEN n=13 THEN '273b057e-3b69-46e3-93c1-6194c2802849'::uuid
 ELSE '8bc9eef5-dcd5-46b1-b931-23f77132322c'::uuid END,'cashier','Payment fixture '||n,true
 FROM generate_series(11,13)n;
INSERT INTO public.user_store_access(user_id,store_id,is_primary,is_active,source_type)
SELECT id,restaurant_id,true,true,'direct' FROM public.users WHERE auth_id IN(
 '92000000-0000-4000-8000-000000000011','92000000-0000-4000-8000-000000000012',
 '92000000-0000-4000-8000-000000000013');
SELECT set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000099',true);
INSERT INTO public.menu_items(id,restaurant_id,name,name_vi,price,invoice_sale_unit)
VALUES('95000000-0000-4000-8000-000000000001','8bc9eef5-dcd5-46b1-b931-23f77132322c',
 'Receipt fixture dish','Món kiểm tra biên nhận',10000,'Phần');
INSERT INTO public.inventory_items(id,restaurant_id,name,unit,current_stock)
VALUES('95000000-0000-4000-8000-000000000002','8bc9eef5-dcd5-46b1-b931-23f77132322c','Receipt fixture stock','g',10000);
INSERT INTO public.menu_recipes(restaurant_id,menu_item_id,ingredient_id,quantity_g)
VALUES('8bc9eef5-dcd5-46b1-b931-23f77132322c','95000000-0000-4000-8000-000000000001',
 '95000000-0000-4000-8000-000000000002',10);
INSERT INTO public.orders(id,restaurant_id,status)
SELECT id::uuid,'8bc9eef5-dcd5-46b1-b931-23f77132322c','serving' FROM unnest(ARRAY[
 '95000000-0000-4000-8000-000000000010','95000000-0000-4000-8000-000000000020',
 '95000000-0000-4000-8000-000000000030'])id;
INSERT INTO public.order_items(restaurant_id,order_id,menu_item_id,item_type,label,display_name,unit_price,quantity,status)
SELECT restaurant_id,id,'95000000-0000-4000-8000-000000000001','menu_item','Receipt fixture dish',
 'Receipt fixture dish',10000,CASE WHEN id='95000000-0000-4000-8000-000000000020' THEN 1 ELSE 3 END,'served'
FROM public.orders WHERE id IN('95000000-0000-4000-8000-000000000010','95000000-0000-4000-8000-000000000020',
 '95000000-0000-4000-8000-000000000030');
COMMIT;
""")
    kds=call("SELECT public.get_kds_progress_receipts_v1('"+STORE+"','{}'::uuid[]);",
             actor='92000000-0000-4000-8000-000000000006')
    check(json.loads(kds.stdout)==[],'kds-current-schema-scalar-access-contract')
    # Discard the first response, then reconcile by original identity. A second
    # delivery must return the same row even though the order is still unpaid.
    call(once())
    row=receipts([OP])[0]
    repeated=json.loads(call(once(amount='8000.00')).stdout)
    check(repeated['id']==row['payment_id'],'lost-response-partial-idempotence')
    actual=json.loads(sql("SELECT jsonb_build_object('count',count(*),'sum',sum(amount)) FROM public.payments WHERE order_id='"+PARTIAL+"';").stdout)
    check(actual=={'count':1,'sum':8000},'partial-payment-is-applied-once')
    check(receipts([OP,OP])[0]==row and len(receipts([OP,OP]))==1,'duplicate-read-ids-deduplicated')
    check(receipts([])==[] and receipts(['96000000-0000-4000-8000-000000000099'])==[],'empty-and-missing-are-empty')
    check(receipts([OP],actor=OTHER)==[],'same-store-other-actor-cannot-read')
    for label,body in [('amount',once(amount=9000)),('method',once(method='BANKTRANSFER')),
                       ('order',once(order=FULL))]:
        response=call(body,check_result=False)
        check(response.returncode!=0 and 'PAYMENT_OPERATION_CONFLICT' in response.stderr,'reused-id-conflict-'+label)
    denied=call(once(),actor=OUTSIDE,check_result=False)
    check(denied.returncode!=0 and 'PAYMENT_FORBIDDEN' in denied.stderr,'outside-store-denied')
    for ids in ["ARRAY[NULL]::uuid[]", "array_fill('"+OP+"'::uuid,ARRAY[101])"]:
        response=call("SELECT public.get_payment_command_receipts_v1('"+STORE+"',"+ids+");",check_result=False)
        check(response.returncode!=0 and 'PAYMENT_RECEIPT_BATCH_INVALID' in response.stderr,'bounded-receipt-input-'+str(len(checks)))
    failed=call(once(operation='96000000-0000-4000-8000-000000000099',amount=999999),check_result=False)
    check(failed.returncode!=0 and 'PAYMENT_AMOUNT_EXCEEDS_REMAINING' in failed.stderr,'native-rejection-preserved')
    check(receipts(['96000000-0000-4000-8000-000000000099'])==[],'failed-native-write-has-no-receipt')
    # Current authorization is evaluated again, including an already confirmed ID.
    sql("UPDATE public.users SET is_active=false WHERE auth_id='"+ACTOR+"';")
    for body in [once(),"SELECT public.get_payment_command_receipts_v1('"+STORE+"',ARRAY['"+OP+"']::uuid[]);"]:
        denied=call(body,check_result=False)
        check(denied.returncode!=0 and 'PAYMENT_FORBIDDEN' in denied.stderr,'revoked-actor-denied-'+str(len(checks)))
    sql("UPDATE public.users SET is_active=true WHERE auth_id='"+ACTOR+"';")
    denied=call('SELECT * FROM pos_command_private.payment_receipts;',check_result=False)
    check(denied.returncode!=0,'private-table-unreadable')
    denied=sql("SET ROLE anon;SELECT public.process_payment_once_v1('"+OP+"','"+PARTIAL+"','"+STORE+"',8000,'CASH');",check=False)
    check(denied.returncode!=0,'anonymous-execution-denied')
    # Four workers, eight deliveries, one native full payment. This uses actual
    # functions/triggers and verifies stock/invoice effects, not a stub counter.
    started=time.monotonic()
    with ThreadPoolExecutor(max_workers=4) as pool:
        responses=list(pool.map(lambda _:json.loads(call(once(FULL_OP,FULL,10800)).stdout),range(8)))
    check(len({r['id'] for r in responses})==1,'concurrent-replay-one-payment-id')
    final=json.loads(sql("""SELECT jsonb_build_object(
 'payments',(SELECT count(*) FROM public.payments WHERE order_id='95000000-0000-4000-8000-000000000020'),
 'paid',(SELECT sum(amount) FROM public.payments WHERE order_id='95000000-0000-4000-8000-000000000020'),
 'stock',(SELECT sum(t.quantity_g) FROM public.inventory_transactions t JOIN public.order_items i ON i.id=t.reference_id WHERE i.order_id='95000000-0000-4000-8000-000000000020'),
 'invoice_jobs',(SELECT count(*) FROM public.meinvoice_jobs WHERE order_id='95000000-0000-4000-8000-000000000020'),
 'status',(SELECT status FROM public.orders WHERE id='95000000-0000-4000-8000-000000000020'));
""").stdout)
    check(final=={'payments':1,'paid':10800,'stock':-10,'invoice_jobs':1,'status':'completed'},'native-money-stock-invoice-exactly-once')
    with ThreadPoolExecutor(max_workers=2) as pool:
        conflicts=list(pool.map(lambda amount:call(once(RACE_OP,RACE,amount),check_result=False),[7000,8000]))
    check(sorted(r.returncode==0 for r in conflicts)==[False,True]
          and any('PAYMENT_OPERATION_CONFLICT' in r.stderr for r in conflicts),'concurrent-different-payload-rejected')
    check(len(receipts([RACE_OP,FULL_OP,OP]))==3,'set-based-confirmed-results')
    return {'checksPassed':checks,'count':len(checks),'concurrentDeliveries':8,'maxWorkers':4,
            'fixtureSha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            'replayConflictAndResultLookupWallSeconds':time.monotonic()-started,
            'nativePaymentFunctionsStubbed':False,'externalProviderCalled':False,
            'browserTransportFaultInjected':False}
