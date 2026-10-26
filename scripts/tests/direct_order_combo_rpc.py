"""Exercise combo pages, submit and approval races through isolated PostgREST."""
import base64, concurrent.futures, hashlib, hmac, json, subprocess, sys, time, urllib.error, urllib.request, uuid
from pathlib import Path
container=sys.argv[1]
shop='d1000000-0000-4000-8000-000000000002'
def sql(q):
 r=subprocess.run(['docker','exec',container,'psql','-X','-At','-U','postgres','-d','codex_direct_photo','-v','ON_ERROR_STOP=1','-c',q],capture_output=True,text=True)
 if r.returncode: raise RuntimeError(r.stderr)
 return r.stdout.strip().splitlines()[-1]
claims_function="CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql AS $$ SELECT (nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'sub')::uuid $$"
sql(claims_function)
network=json.loads(subprocess.check_output(['docker','inspect',container]))[0]['NetworkSettings']
ip=next(iter(network['Networks'].values()))['IPAddress']
rest=container+'-combo-rest'; secret='disposable-combo-jwt-fixture-only-20261013'
subprocess.run(['docker','run','-d','--rm','--name',rest,'-p','127.0.0.1::3000','-e',f'PGRST_DB_URI=postgres://postgres@{ip}:5432/codex_direct_photo','-e','PGRST_DB_ANON_ROLE=anon','-e',f'PGRST_JWT_SECRET={secret}','-e','PGRST_DB_SCHEMAS=public','public.ecr.aws/supabase/postgrest:v14.5'],check=True,capture_output=True)
def token(role):
 def enc(x): return base64.urlsafe_b64encode(json.dumps(x,separators=(',',':')).encode()).rstrip(b'=')
 body=enc({'alg':'HS256','typ':'JWT'})+b'.'+enc({'role':role,'sub':'00000000-0000-4000-8000-000000000001','exp':int(time.time())+3600})
 return (body+b'.'+base64.urlsafe_b64encode(hmac.new(secret.encode(),body,hashlib.sha256).digest()).rstrip(b'=')).decode()
try:
 # Resolve the client endpoint so the same fixture works from a local tool
 # container without assuming Docker Desktop's published host port is local.
 address=subprocess.check_output(['docker','port',rest,'3000/tcp'],text=True).strip()
 assert address.startswith('127.0.0.1:'), 'Expected a loopback-only fixture endpoint'
 base='http://'+address
 for attempt in range(60):
  try: urllib.request.urlopen(base,timeout=1); break
  except urllib.error.URLError: time.sleep(.2)
 def rpc(name,payload,role='service_role'):
  req=urllib.request.Request(base+'/rpc/'+name,data=json.dumps(payload).encode(),headers={'Content-Type':'application/json','Authorization':'Bearer '+token(role)})
  start=time.perf_counter()
  try:
   with urllib.request.urlopen(req,timeout=20) as response: raw=response.read()
  except urllib.error.HTTPError as e: raise RuntimeError(e.read().decode()) from e
  return json.loads(raw),round((time.perf_counter()-start)*1000,3),len(raw)
 slug=sql(f"SELECT public_slug FROM direct_order_storefronts WHERE restaurant_id='{shop}'")
 page,page_ms,page_bytes=rpc('direct_order_public_storefront_v3',{'p_slug':slug,'p_limit':200})
 assert any(x['is_combo'] for x in page['items']) and page['combo_drink_options']
 session,_,_=rpc('direct_order_public_create_session',{'p_slug':slug,'p_secret_hash':hashlib.sha256(uuid.uuid4().bytes).hexdigest(),'p_locale':'vi'})
 session_id=session['session_id']; session_hash=sql(f"SELECT secret_hash FROM direct_order_sessions WHERE id='{session_id}'")
 payload={'p_session_id':session_id,'p_secret_hash':session_hash,'p_client_request_id':str(uuid.uuid4()),'p_payload':{'locale':'vi','fulfillment_type':'delivery','diner_count':1,'address':{'customer_name':'Fixture only','customer_phone':'0901234567','formatted_address':'123 Fixture Street','detail_address':'Door','address_source':'manual'},'items':[{'menu_item_id':'c5000000-0000-4000-8000-000000000005','quantity':1,'combo_drink_choices':['c5000000-0000-4000-8000-000000000003']}]}}
 with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool: results=list(pool.map(lambda _:rpc('direct_order_public_submit_v3',payload),range(2)))
 assert results[0][0]['request_id']==results[1][0]['request_id']; rid=results[0][0]['request_id']
 q,quote_ms,_=rpc('direct_order_staff_quote_with_payment_mode',{'p_store_id':shop,'p_request_id':rid,'p_delivery_fee_total':0,'p_delivery_payment_mode':'customer_direct'},'authenticated')
 proof=sql(f"UPDATE direct_order_requests SET state='awaiting_payment_review' WHERE id='{rid}'; UPDATE direct_order_quotes SET status='locked' WHERE id='{q['id']}'; INSERT INTO direct_order_messages(request_id,restaurant_id,sender_type,message_type,body,attachment_storage_path,metadata) VALUES('{rid}','{shop}','customer','payment_proof','Fixture only','{shop}/{rid}/00000000-0000-4000-8000-000000000009.jpg',jsonb_build_object('quote_id','{q['id']}','quote_version','1')) RETURNING id")
 # psql command tags follow RETURNING output; fetch the scoped latest proof.
 proof=sql(f"SELECT id FROM direct_order_messages WHERE request_id='{rid}' AND message_type='payment_proof' ORDER BY created_at DESC LIMIT 1")
 before=float(sql("SELECT current_stock FROM inventory_items WHERE id='c6000000-0000-4000-8000-000000000001'"))
 approval={'p_store_id':shop,'p_request_id':rid,'p_amount':q['final_total'],'p_bank_reference':'Fixture-'+rid,'p_quote_id':q['id'],'p_proof_message_id':proof}
 with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool: approvals=list(pool.map(lambda _:rpc('direct_order_record_receipt',approval,'authenticated'),range(2)))
 after=float(sql("SELECT current_stock FROM inventory_items WHERE id='c6000000-0000-4000-8000-000000000001'"))
 assert before-after==12 and sql(f"SELECT count(*) FROM direct_order_financials WHERE request_id='{rid}'")=='1'
 evidence={'transport':'local disposable PostgREST; not production latency','menu_page_calls':1,'menu_rows':len(page['items']),'menu_bytes':page_bytes,'menu_ms':page_ms,'submit_calls':2,'logical_requests':1,'submit_ms':[x[1] for x in results],'quote_calls':1,'quote_ms':quote_ms,'approval_calls':2,'logical_payments':1,'stock_deducted':before-after,'approval_ms':[x[1] for x in approvals]}
 out=Path('outputs/direct-order-combo-20261013'); out.mkdir(parents=True,exist_ok=True); (out/'rpc_measurements.json').write_text(json.dumps(evidence,indent=2)+'\n')
 print('COMBO_REAL_POSTGREST=PASS',json.dumps(evidence))
finally: subprocess.run(['docker','rm','-f',rest],capture_output=True)
