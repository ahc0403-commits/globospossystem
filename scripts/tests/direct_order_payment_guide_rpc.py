"""Actual PostgREST paths against the disposable quote fixture; no live data."""
import concurrent.futures
import json
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

container = sys.argv[1]
shop = 'd1000000-0000-4000-8000-000000000002'

def sql(query):
    result = subprocess.run(['docker','exec',container,'psql','-X','-At','-U','postgres','-d','codex_direct_photo','-v','ON_ERROR_STOP=1','-c',query],capture_output=True,text=True)
    if result.returncode: raise RuntimeError(result.stderr)
    return result.stdout.strip().splitlines()[-1]

network = json.loads(subprocess.check_output(['docker','inspect',container]))[0]['NetworkSettings']
ip = next(iter(network['Networks'].values()))['IPAddress']
assert ip, 'Disposable PostgreSQL has no bridge address'
rest_name = container + '-guide-rest'
subprocess.run(['docker','run','-d','--rm','--name',rest_name,'-p','127.0.0.1::3000','-e',f'PGRST_DB_URI=postgres://postgres@{ip}:5432/codex_direct_photo','-e','PGRST_DB_ANON_ROLE=authenticated','-e','PGRST_DB_SCHEMAS=public','public.ecr.aws/supabase/postgrest:v14.5'],check=True,capture_output=True)
try:
    info = json.loads(subprocess.check_output(['docker','inspect',rest_name]))[0]
    port = info['NetworkSettings']['Ports']['3000/tcp'][0]['HostPort']
    base = f'http://127.0.0.1:{port}'
    for attempt in range(60):
        try: urllib.request.urlopen(base,timeout=1); break
        except (urllib.error.URLError,ConnectionError): time.sleep(.2)
    else:
        raise RuntimeError(subprocess.check_output(['docker','logs',rest_name],stderr=subprocess.STDOUT).decode()[-6000:])
    def rpc(name,payload):
        request=urllib.request.Request(base+'/rpc/'+name,data=json.dumps(payload).encode(),headers={'Content-Type':'application/json'})
        start=time.perf_counter()
        try:
            with urllib.request.urlopen(request,timeout=15) as response: data=response.read()
        except urllib.error.HTTPError as e: raise RuntimeError(e.read().decode()+'\n'+subprocess.check_output(['docker','logs',rest_name],stderr=subprocess.STDOUT).decode()[-3500:]) from e
        return json.loads(data),(time.perf_counter()-start)*1000,len(data)
    paths=[]
    for n in [1,20,100]:
        request_id=sql(f'SELECT guide_test.request({n})')
        preview,preview_ms,preview_size=rpc('direct_order_staff_detail_v7',{'p_store_id':shop,'p_request_id':request_id})
        assert preview['amount_summary']['amounts']['final_total']==108000*n and not preview['amount_summary']['finalized']
        payload={'p_store_id':shop,'p_request_id':request_id,'p_delivery_fee_total':0,'p_delivery_payment_mode':'customer_direct'}
        if n==1:
            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                outcomes=list(pool.map(lambda _:rpc('direct_order_staff_quote_with_payment_mode',payload),range(2)))
            assert outcomes[0][0]['id']==outcomes[1][0]['id']
            quote,ms,size=outcomes[0]
        else: quote,ms,size=rpc('direct_order_staff_quote_with_payment_mode',payload)
        detail,read_ms,read_size=rpc('direct_order_staff_detail_v7',{'p_store_id':shop,'p_request_id':request_id})
        assert quote['final_total']==108000*n and detail['amount_summary']['finalized']
        assert sql(f"SELECT count(*) FROM direct_order_quotes WHERE request_id='{request_id}'")=='1'
        assert sql(f"SELECT count(*) FROM direct_order_messages WHERE request_id='{request_id}' AND message_type='quote'")=='1'
        if n==1:
            link_payload={'p_store_id':shop,'p_request_id':request_id,'p_operation_id':str(uuid.uuid4()),'p_access_key':'z'*43,'p_public_origin':'https://globospossystem.vercel.app','p_send_to_customer':True}
            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                links=list(pool.map(lambda _:rpc('direct_order_staff_issue_order_link',link_payload),range(2)))
            assert links[0][0]['message_id']==links[1][0]['message_id']
        paths.append({'lines':n,'preview_read_calls':1,'preview_ms':round(preview_ms,3),'preview_bytes':preview_size,'logical_quote_writes':1,'physical_quote_calls':2 if n==1 else 1,'detail_read_calls':1,'quote_ms':round(ms,3),'quote_bytes':size,'detail_ms':round(read_ms,3),'detail_bytes':read_size})
    out=Path('outputs/direct-order-payment-guide-20261013');out.mkdir(parents=True,exist_ok=True)
    (out/'rpc_measurements.json').write_text(json.dumps({'transport':'local disposable PostgREST HTTP; not production latency/app memory','paths':paths,'concurrent_first_quote':'one quote and one quote message','concurrent_order_link':'one scoped key and one customer message'},indent=2)+'\n')
    print('PAYMENT_GUIDE_REAL_POSTGREST=PASS',json.dumps(paths))
finally:
    subprocess.run(['docker','rm','-f',rest_name],capture_output=True)
