"""Native single-payment intent cancellation/concurrency cases in an owned DB."""
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path

STORE='8bc9eef5-dcd5-46b1-b931-23f77132322c'
ACTOR='92000000-0000-4000-8000-000000000011'
OTHER='92000000-0000-4000-8000-000000000012'


def run(sql):
    checks=[]
    def check(ok,name):
        if not ok:raise RuntimeError('Native payment v2 fixture failed: '+name)
        checks.append(name)
    def order(n):return '97000000-0000-4000-8000-'+str(n).zfill(12)
    def operation(n):return '98000000-0000-4000-8000-'+str(n).zfill(12)
    def call(body,actor=ACTOR,check_result=True):
        return sql("BEGIN;SET LOCAL ROLE authenticated;SET LOCAL request.jwt.claim.role='authenticated';"
          "SET LOCAL request.jwt.claim.sub='"+actor+"';"+body+'COMMIT;',check=check_result)
    def pay(n,op=None,amount=8000,count=0,full=False,check_result=True):
        return call("SELECT public.process_single_payment_command_v2('"+(op or operation(n))+"','"+
          order(n)+"','"+STORE+"',"+str(amount)+",'CASH',"+str(count)+','+str(full).lower()+');',check_result=check_result)
    def cancel(n,op=None,actor=ACTOR,check_result=True):
        return call("SELECT public.cancel_single_payment_command_v1('"+(op or operation(n))+"','"+
          order(n)+"','"+STORE+"');",actor,check_result)
    def counts(n):
        return json.loads(sql("SELECT jsonb_build_object('payments',(SELECT count(*) FROM public.payments WHERE order_id='"+order(n)+"'),"
          "'receipts',(SELECT count(*) FROM pos_command_private.payment_receipts WHERE order_id='"+order(n)+"'),"
          "'jobs',(SELECT count(*) FROM public.meinvoice_jobs WHERE order_id='"+order(n)+"'));" ).stdout)
    sql("""
BEGIN;
SELECT set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000099',true);
INSERT INTO public.orders(id,restaurant_id,status)
SELECT ('97000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,
 '8bc9eef5-dcd5-46b1-b931-23f77132322c','serving' FROM generate_series(1,8)n;
INSERT INTO public.order_items(restaurant_id,order_id,menu_item_id,item_type,label,display_name,unit_price,quantity,status)
SELECT o.restaurant_id,o.id,'95000000-0000-4000-8000-000000000001','menu_item','Receipt v2 fixture',
 'Receipt v2 fixture',10000,CASE WHEN o.id='97000000-0000-4000-8000-000000000004' THEN 1 ELSE 3 END,'served'
FROM public.orders o WHERE o.id BETWEEN '97000000-0000-4000-8000-000000000001' AND '97000000-0000-4000-8000-000000000008';
COMMIT;
""")
    first=json.loads(cancel(1).stdout)
    repeated=json.loads(cancel(1).stdout)
    check(first['status']=='cancelled' and first==repeated,'cancel-barrier-replay-is-immutable')
    denied=pay(1,check_result=False)
    check(denied.returncode!=0 and 'PAYMENT_OPERATION_CANCELLED' in denied.stderr,'cancel-before-late-v2-delivery')
    legacy=call("SELECT public.process_payment_once_v1('"+operation(1)+"','"+order(1)+"','"+STORE+"',8000,'CASH');",check_result=False)
    check(legacy.returncode!=0 and 'PAYMENT_OPERATION_CANCELLED' in legacy.stderr,'legacy-once-cannot-bypass-cancel-barrier')
    check(counts(1)=={'payments':0,'receipts':0,'jobs':0},'cancelled-intent-has-no-financial-effects')
    # This creates native payment/stock/audit effects, then rejects the stale
    # full-payment intent. The outer RPC transaction must roll them all back.
    rejected=pay(2,full=True,check_result=False)
    check(rejected.returncode!=0 and 'PAYMENT_ORDER_CHANGED' in rejected.stderr,'full-intent-cannot-silently-become-partial')
    check(counts(2)=={'payments':0,'receipts':0,'jobs':0},'stale-full-payment-rolled-back-with-receipt')
    stock=sql("SELECT count(*) FROM public.inventory_transactions t JOIN public.order_items i ON i.id=t.reference_id WHERE i.order_id='"+order(2)+"';").stdout.strip()
    check(stock=='0','stale-full-payment-stock-rolled-back')
    mismatched=pay(3,count=1,check_result=False)
    check(mismatched.returncode!=0 and 'PAYMENT_ORDER_CHANGED' in mismatched.stderr,'stale-payment-count-rejected-before-charge')
    saved=json.loads(pay(3).stdout)
    replay=json.loads(pay(3).stdout)
    check(saved['id']==replay['id'] and counts(3)['payments']==1,'partial-original-id-survives-stale-count-on-replay')
    confirmed=json.loads(cancel(3).stdout)
    check(confirmed['status']=='confirmed' and confirmed['result']['id']==saved['id'],'cancel-after-commit-returns-original-confirmation')
    changed=pay(3,full=True,check_result=False)
    check(changed.returncode!=0 and 'PAYMENT_OPERATION_CONFLICT' in changed.stderr,'reused-id-cannot-change-full-intent')
    paid=json.loads(pay(4,amount=10800,full=True).stdout)
    check(json.loads(pay(4,amount=10800,full=True).stdout)['id']==paid['id'],'full-completed-order-replay-returns-original-row')
    check(counts(4)=={'payments':1,'receipts':1,'jobs':1},'full-intent-has-one-payment-and-invoice')
    # Distinct intents on the same stale payment version cannot both charge.
    with ThreadPoolExecutor(max_workers=2) as pool:
        race=list(pool.map(lambda op:pay(5,op=op,check_result=False),[operation(50),operation(51)]))
    check(sum(r.returncode==0 for r in race)==1 and any('PAYMENT_ORDER_CHANGED' in r.stderr for r in race),
          'different-intents-on-same-payment-version-charge-once')
    check(counts(5)['payments']==counts(5)['receipts']==1,'stale-parallel-cashier-has-no-second-payment')
    # Cancel and late delivery serialize by the same original operation lock.
    with ThreadPoolExecutor(max_workers=2) as pool:
        futures=[pool.submit(pay,6,check_result=False),pool.submit(cancel,6,check_result=False)]
        pay_result,cancel_result=[f.result() for f in futures]
    outcome=json.loads(cancel_result.stdout)
    if outcome['status']=='confirmed':
        check(pay_result.returncode==0 and counts(6)['payments']==1,'commit-wins-cancel-race-with-one-result')
    else:
        check(outcome['status']=='cancelled' and pay_result.returncode!=0
              and 'PAYMENT_OPERATION_CANCELLED' in pay_result.stderr and counts(6)['payments']==0,
              'cancel-wins-late-delivery-race-with-no-charge')
    conflict=cancel(7,op=operation(1),check_result=False)
    check(conflict.returncode!=0 and 'PAYMENT_OPERATION_CONFLICT' in conflict.stderr,'cancel-reused-id-other-order-rejected')
    other=json.loads(cancel(7,op=operation(1),actor=OTHER).stdout)
    check(other['status']=='cancelled','different-actors-have-independent-operation-identities')
    sql("UPDATE public.users SET is_active=false WHERE auth_id='"+ACTOR+"';")
    revoked=cancel(1,check_result=False)
    check(revoked.returncode!=0 and 'PAYMENT_FORBIDDEN' in revoked.stderr,'revoked-actor-cannot-resolve-or-cancel')
    sql("UPDATE public.users SET is_active=true WHERE auth_id='"+ACTOR+"';")
    denied=call('SELECT * FROM pos_command_private.payment_cancellations;',check_result=False)
    check(denied.returncode!=0,'cancellation-ledger-is-private')
    return {'count':len(checks),'checksPassed':checks,'nativeFinancialFunctionsStubbed':False,
            'fixtureSha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            'maxWorkers':2,'productionModified':False}
