"""A concurrent stock write invalidates preview; refreshed completion preserves it."""
import json, subprocess, sys, time
port=sys.argv[1]
base=['psql','-X','-h','127.0.0.1','-p',port,'-d','postgres','-v','ON_ERROR_STOP=1','-At']
store='8bc9eef5-dcd5-46b1-b931-23f77132322c'
def sql(query):
    result=subprocess.run(base+['-c',query],text=True,capture_output=True)
    if result.returncode: raise RuntimeError(result.stderr)
    return result.stdout.strip()
def value(query):
    return json.loads(sql("SET request.jwt.claim.role='service_role'; "+query).splitlines()[-1])
session=value("SELECT prepare_inventory_stock_audit_v2('"+store+"',(clock_timestamp() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date,clock_timestamp());")
sid=session['id']; item=session['snapshot'][0]['inventory_item_id']
lines=[{'product_id':r['product_id'],'actual_quantity_base':7,'counted_at':session['effective_at']} for r in session['snapshot']]
encoded=json.dumps(lines).replace("'","''")
preview=value("SELECT preview_inventory_stock_audit_v3('"+store+"','"+sid+"','"+encoded+"');")
writer=subprocess.Popen(base+['-c',"SET application_name='dated-stock-writer'; BEGIN; UPDATE inventory_items SET current_stock=current_stock+5 WHERE id='"+item+"'; SELECT pg_sleep(2); COMMIT;"],text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
for _ in range(50):
    if sql("SELECT count(*) FROM pg_stat_activity WHERE application_name='dated-stock-writer' AND wait_event='PgSleep';")=='1': break
    time.sleep(.05)
else: raise AssertionError('stock writer did not acquire row lock')
query="SELECT save_inventory_stock_audit_v3('"+store+"','"+sid+"',1,'"+encoded+"',true,NULL,'"+preview['token']+"');"
result=subprocess.run(base+['-c',"SET request.jwt.claim.role='service_role'; "+query],text=True,capture_output=True)
out,err=writer.communicate(timeout=10)
assert writer.returncode==0,err
assert result.returncode!=0 and 'PREVIEW_CHANGED' in result.stderr,result.stderr
assert sql("SELECT status FROM inventory_stock_audit_sessions WHERE id='"+sid+"';")=='planned'
preview=value("SELECT preview_inventory_stock_audit_v3('"+store+"','"+sid+"','"+encoded+"');")
expected=next(r['current_after_base'] for r in preview['rows'] if r['inventory_item_id']==item)
assert expected==12,expected
value(query.replace(query.split("NULL,'")[1].split("'")[0],preview['token']))
assert float(sql("SELECT current_stock FROM inventory_items WHERE id='"+item+"';"))==12
print('Concurrent commerce: stale preview rolls back; refreshed count preserves +5 exactly once: PASS')
