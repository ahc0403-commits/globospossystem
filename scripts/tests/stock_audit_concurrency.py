"""Real row-lock contention: a count cannot overwrite a concurrent stock movement."""
import json,subprocess,sys,time
port=sys.argv[1]
base=['psql','-X','-h','127.0.0.1','-p',port,'-d','postgres','-v','ON_ERROR_STOP=1','-At']
store='8bc9eef5-dcd5-46b1-b931-23f77132322c'
def sql(query):
 r=subprocess.run(base+['-c',query],text=True,capture_output=True)
 if r.returncode:raise RuntimeError(r.stderr)
 return r.stdout.strip()
session=json.loads(sql("SET request.jwt.claim.role='service_role'; SELECT public.prepare_inventory_stock_audit('"+store+"');").splitlines()[-1])
sid=session['id'];item=session['snapshot'][0]['inventory_item_id']
lines=sql("SELECT jsonb_agg(jsonb_build_object('product_id',x->>'product_id','actual_quantity_base',7,'counted_at',now()::text)) FROM inventory_stock_audit_sessions s CROSS JOIN LATERAL jsonb_array_elements(s.count_snapshot)x WHERE s.id='"+sid+"';")
before=sql('SELECT count(*) FROM inventory_transactions;')
writer=subprocess.Popen(base+['-c',"SET application_name='stock-movement-test'; BEGIN; UPDATE inventory_items SET current_stock=current_stock+1,updated_at=clock_timestamp() WHERE id='"+item+"'; SELECT pg_sleep(2); COMMIT;"],text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
for attempt in range(30):
 if sql("SELECT count(*) FROM pg_stat_activity WHERE application_name='stock-movement-test' AND wait_event='PgSleep';")=='1':break
 time.sleep(0.05)
else:raise AssertionError('writer never acquired inventory row lock')
count=subprocess.run(base+['-c',"SET request.jwt.claim.role='service_role'; SELECT public.save_inventory_stock_audit_v2('"+store+"','"+sid+"',1,'"+lines.replace("'","''")+"'::jsonb,true);"],text=True,capture_output=True)
stdout,stderr=writer.communicate(timeout=10)
assert writer.returncode==0,stderr
assert count.returncode!=0 and 'INVENTORY_STOCK_AUDIT_STOCK_CHANGED' in count.stderr,count.stderr
assert sql('SELECT count(*) FROM inventory_transactions;')==before
assert sql("SELECT current_stock FROM inventory_items WHERE id='"+item+"';")=='1'
assert sql("SELECT status FROM inventory_stock_audit_sessions WHERE id='"+sid+"';")=='planned'
print('Concurrent receipt/stock movement blocks stale completion: PASS')
