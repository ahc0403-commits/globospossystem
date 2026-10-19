"""Current canonical worker tables + service grants, isolated concurrent RPCs."""
from pathlib import Path
import subprocess,json,re,time,os,uuid,sys,concurrent.futures
root=Path(__file__).resolve().parents[3];out=Path(sys.argv[1] if len(sys.argv)>1 else '/tmp/pos-claim-verification');out.mkdir(parents=True,exist_ok=True)
name='pos-claims-'+str(os.getpid())
def run(*a,input=None):return subprocess.check_output(a,input=input,text=True,stderr=subprocess.STDOUT)
def sql(q):return run('docker','exec','-i',name,'psql','-XqAt','-U','postgres','-d','claims','-v','ON_ERROR_STOP=1',input=q).strip()
def load(p):return sql((root/p).read_text())
def table(p,n):s=(root/p).read_text();m=re.search(r'CREATE TABLE (?:IF NOT EXISTS )?public\.'+n+r' \([\s\S]*?\n\);',s);assert m,n;return m[0]
def service(q):return sql("SET ROLE service_role;SELECT set_config('request.jwt.claim.role','service_role',false);"+q).splitlines()[-1]
results=[]
try:
 run('docker','run','--detach','--rm','--name',name,'--cpus','2','--memory','1g','--env','POSTGRES_HOST_AUTH_METHOD=trust','--env','POSTGRES_DB=claims','postgres:15')
 for _ in range(60):
  try:sql('SELECT 1');break
  except subprocess.CalledProcessError:time.sleep(.25)
 sql("""CREATE ROLE anon;CREATE ROLE authenticated;CREATE ROLE service_role;CREATE SCHEMA auth;
 CREATE FUNCTION auth.role() RETURNS text LANGUAGE sql STABLE AS $$SELECT current_setting('request.jwt.claim.role',true)$$;
 GRANT USAGE ON SCHEMA public,auth TO service_role,authenticated;GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA auth TO service_role,authenticated;
 CREATE TABLE restaurants(id uuid PRIMARY KEY);CREATE TABLE users(id uuid PRIMARY KEY);CREATE TABLE orders(id uuid PRIMARY KEY);CREATE TABLE tax_entity(id uuid PRIMARY KEY);
 CREATE TABLE emergency_station_assignments(id uuid PRIMARY KEY);CREATE TABLE emergency_fulfillment_events(event_id uuid PRIMARY KEY);
 CREATE FUNCTION test_uuid(n integer) RETURNS uuid LANGUAGE sql IMMUTABLE AS $$ SELECT ('00000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid $$;
 INSERT INTO restaurants VALUES(test_uuid(1));INSERT INTO users VALUES(test_uuid(1));INSERT INTO tax_entity SELECT test_uuid(n) FROM generate_series(1,50)n;
 INSERT INTO orders SELECT test_uuid(n) FROM generate_series(1,1000)n;INSERT INTO emergency_station_assignments VALUES(test_uuid(1));INSERT INTO emergency_fulfillment_events VALUES(test_uuid(1));
 """)
 for t in ['emergency_web_push_devices','emergency_push_deliveries']:sql(table('supabase/migrations/20260810170000_emergency_digital_fulfillment.sql',t))
 for p,t in [('supabase/migrations/20260630000000_wetax_shutdown_meinvoice_foundation.sql','meinvoice_jobs'),('supabase/migrations/20260630002000_meinvoice_dispatcher_foundation.sql','meinvoice_job_events')]:sql(table(p,t))
 sql('ALTER TABLE meinvoice_jobs ADD COLUMN dispatch_attempts integer NOT NULL DEFAULT 0,ADD COLUMN last_dispatch_at timestamptz,ADD COLUMN sent_at timestamptz;')
 for p in ['supabase/migrations/20261011060000_emergency_push_batch_lease.sql','supabase/migrations/20261011080000_meinvoice_owned_batches.sql']:load(p);load(p)
 sql("INSERT INTO emergency_web_push_devices(id,restaurant_id,user_id,station_assignment_id,token) SELECT test_uuid(n),test_uuid(1),test_uuid(1),test_uuid(1),'fixture-token-00000-'||n FROM generate_series(1,1000)n;")
 for kind in ['emergency','misa']:
  for n in [1,50,1000]:
   for concurrency in [1,2,8]:
    if kind=='emergency':sql(f"TRUNCATE emergency_push_deliveries;UPDATE emergency_web_push_devices SET token='fixture-token-00000-'||right(id::text,12)::integer,is_enabled=true;INSERT INTO emergency_push_deliveries(id,event_id,restaurant_id,device_id,push_token,station_type,order_id,stage) SELECT test_uuid(i),test_uuid(1),test_uuid(1),test_uuid(i),'fixture-token-00000-'||i,'kitchen',test_uuid(i),'cooking' FROM generate_series(1,{n})i;")
    else:sql(f"TRUNCATE meinvoice_jobs CASCADE;INSERT INTO meinvoice_jobs(id,order_id,store_id,tax_entity_id,payment_method_snapshot,status) SELECT ('00000000-0000-7000-8000-'||lpad(i::text,12,'0'))::uuid,test_uuid(i),test_uuid(1),test_uuid(1+(i-1)%50),'Tien mat','pending' FROM generate_series(1,{n})i;")
    owners=[str(uuid.uuid4()) for _ in range(concurrency)]
    def claim(owner):
     call=f"claim_emergency_push_batch('{owner}',50)" if kind=='emergency' else f"(SELECT coalesce(jsonb_agg(j),'[]') FROM claim_meinvoice_jobs('{owner}',50)j)"
     return json.loads(service('SELECT '+call))
    start=time.perf_counter()
    with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as pool:data=list(pool.map(claim,owners))
    groups=[r['rows'] if kind=='emergency' else r for r in data];ids=[r['id'] for group in groups for r in group]
    assert len(ids)==len(set(ids))==min(n,50*concurrency),(kind,n,concurrency)
    assert all(len(g)<=50 for g in groups)
    count=0
    for owner,group in zip(owners,groups):
     rows=[{'id':r['id'],'accepted':True} if kind=='emergency' else {'id':r['id'],'status':'valid_invoice','event_type':'dispatch_success'} for r in group]
     complete='complete_emergency_push_batch' if kind=='emergency' else 'complete_meinvoice_batch'
     if rows:
      wrong=int(service(f"SELECT {complete}('{uuid.uuid4()}','{json.dumps(rows)}')"));assert wrong==0
     accepted=int(service(f"SELECT {complete}('{owner}','{json.dumps(rows)}')"));assert accepted==len(rows);count+=accepted
     assert int(service(f"SELECT {complete}('{owner}','{json.dumps(rows)}')"))==0
    results.append({'case':kind,'jobs':n,'dispatchers':concurrency,'claimed':len(ids),'unique':len(set(ids)),'completed':count,'elapsed_ms':1000*(time.perf_counter()-start),'foreign_owner_updates':0,'replayed_completion_updates':0})
 # Expired MISA publish ownership is reconciled, never reclaimed for publishing.
 sql("TRUNCATE meinvoice_jobs CASCADE;INSERT INTO meinvoice_jobs(id,order_id,store_id,tax_entity_id,payment_method_snapshot,status,dispatch_claim_id,dispatch_claim_expires_at) VALUES(test_uuid(1),test_uuid(1),test_uuid(1),test_uuid(1),'Tien mat','pending',test_uuid(99),now()-interval '1 second')")
 assert json.loads(service(f"SELECT coalesce(jsonb_agg(j),'[]') FROM claim_meinvoice_jobs('{uuid.uuid4()}',50)j"))==[]
 assert sql('SELECT status FROM meinvoice_jobs')=='manual_action_required'
 assert sql('SELECT count(*) FROM meinvoice_job_events')=='1'
 # Token invalidation compares the token snapshot to avoid disabling a rotated token.
 sql("TRUNCATE emergency_push_deliveries;UPDATE emergency_web_push_devices SET token='new-rotated-token',is_enabled=true WHERE id=test_uuid(1);INSERT INTO emergency_push_deliveries(id,event_id,restaurant_id,device_id,push_token,station_type,order_id,stage) VALUES(test_uuid(1),test_uuid(1),test_uuid(1),test_uuid(1),'old-token-000000','kitchen',test_uuid(1),'cooking')")
 owner=str(uuid.uuid4());group=json.loads(service(f"SELECT claim_emergency_push_batch('{owner}',50)"));assert len(group['rows'])==1
 p=json.dumps([{'id':group['rows'][0]['id'],'permanent':True,'error':'FCM_UNREGISTERED'}]);assert service(f"SELECT complete_emergency_push_batch('{owner}','{p}')")=='1';assert sql('SELECT is_enabled FROM emergency_web_push_devices WHERE id=test_uuid(1)')=='t'
 # Deferred MISA jobs release ownership without consuming publish attempts.
 sql("TRUNCATE meinvoice_jobs CASCADE;INSERT INTO meinvoice_jobs(id,order_id,store_id,tax_entity_id,payment_method_snapshot,status) VALUES(test_uuid(1),test_uuid(1),test_uuid(1),test_uuid(1),'Tien mat','pending')")
 owner=str(uuid.uuid4());service(f"SELECT coalesce(jsonb_agg(j),'[]') FROM claim_meinvoice_jobs('{owner}',50)j")
 payload=json.dumps([{'id':sql('SELECT test_uuid(1)'),'status':'pending','event_type':'dispatch_deferred'}]);assert service(f"SELECT complete_meinvoice_batch('{owner}','{payload}')")=='1';assert sql('SELECT dispatch_attempts FROM meinvoice_jobs')=='0'
 # Token refresh has exactly one winner across eight independent sessions.
 owners=[str(uuid.uuid4()) for _ in range(8)]
 def token_claim(o):return service(f"SELECT claim_meinvoice_token_refresh(test_uuid(1),'{o}')")
 with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:locks=list(pool.map(token_claim,owners))
 assert locks.count('t')==1 and locks.count('f')==7
 # Legacy completion may not overwrite a new owned claim; expired emergency
 # leases can be reclaimed, but the previous owner may not complete them.
 sql("TRUNCATE emergency_push_deliveries;INSERT INTO emergency_push_deliveries(id,event_id,restaurant_id,device_id,push_token,station_type,order_id,stage) VALUES(test_uuid(1),test_uuid(1),test_uuid(1),test_uuid(1),'new-rotated-token','kitchen',test_uuid(1),'cooking')")
 owner=str(uuid.uuid4());service(f"SELECT claim_emergency_push_batch('{owner}',50)")
 service("SELECT complete_emergency_push_delivery(test_uuid(1),true)");assert sql('SELECT status FROM emergency_push_deliveries')=='sending'
 sql("UPDATE emergency_push_deliveries SET claim_expires_at=now()-interval '1 second'")
 next_owner=str(uuid.uuid4());group=json.loads(service(f"SELECT claim_emergency_push_batch('{next_owner}',50)"));assert len(group['rows'])==1
 payload=json.dumps([{'id':group['rows'][0]['id'],'permanent':True,'error':'FCM_UNREGISTERED'}])
 assert service(f"SELECT complete_emergency_push_batch('{owner}','{payload}')")=='0'
 assert service(f"SELECT complete_emergency_push_batch('{next_owner}','{payload}')")=='1';assert sql('SELECT is_enabled FROM emergency_web_push_devices WHERE id=test_uuid(1)')=='f'
 # Exact canonical current SePay Windows/polling enqueue is retained.
 sql("CREATE TABLE auth.users(id uuid PRIMARY KEY);INSERT INTO auth.users VALUES(test_uuid(1));")
 for path,tab in [('supabase/migrations/20260805120000_sepay_bank_transfer_alerts.sql','sepay_bank_accounts'),('supabase/migrations/20260805120000_sepay_bank_transfer_alerts.sql','sepay_transactions'),('supabase/migrations/20260806110000_sepay_alert_device_delivery_ledger.sql','sepay_alert_devices'),('supabase/migrations/20260806110000_sepay_alert_device_delivery_ledger.sql','sepay_alert_deliveries')]:sql(table(path,tab))
 trigger=(root/'supabase/migrations/20260806120000_sepay_windows_only_alerts.sql').read_text();start=trigger.index('CREATE OR REPLACE FUNCTION public.enqueue_sepay_alert_deliveries()');sql(trigger[start:trigger.index('$$;',start)+3])
 sql("CREATE TRIGGER sepay_alert_delivery_enqueue_trigger AFTER INSERT ON sepay_transactions FOR EACH ROW EXECUTE FUNCTION enqueue_sepay_alert_deliveries();INSERT INTO sepay_bank_accounts(restaurant_id,gateway,account_number) VALUES(test_uuid(1),'fixture','123');INSERT INTO sepay_alert_devices(id,restaurant_id,user_id,installation_id,platform,push_provider,push_token) VALUES(test_uuid(1),test_uuid(1),test_uuid(1),'fixture-windows','windows','polling',NULL),(test_uuid(2),test_uuid(1),test_uuid(1),'fixture-android','android','fcm','fixture-fcm-token-0000')")
 load('supabase/migrations/20261011090000_sepay_delivery_provider_scope.sql');load('supabase/migrations/20261011090000_sepay_delivery_provider_scope.sql')
 q="ingest_sepay_transaction_with_delivery_scope(123,'fixture','123',NULL,'in',1000,NULL,NULL,now(),'{}')"
 sepay=json.loads(service('SELECT '+q));assert sepay['status']=='accepted' and sepay['resolution_status']=='matched' and sepay['push_dispatch_required'] is False
 assert sql('SELECT count(*) FROM sepay_alert_deliveries')=='1' and sql('SELECT device_id=test_uuid(1) FROM sepay_alert_deliveries')=='t'
 assert json.loads(service('SELECT '+q))['status']=='duplicate'
 for fn in ["claim_emergency_push_batch('00000000-0000-4000-8000-000000000001',50)","claim_meinvoice_jobs('00000000-0000-4000-8000-000000000001',50)"]:
  try:sql('SET ROLE authenticated;SELECT '+fn)
  except subprocess.CalledProcessError as e:assert 'permission denied' in e.output
  else:raise AssertionError('Authenticated may claim service-only jobs')
 (out/'results.json').write_text(json.dumps({'environment':'Current canonical queue DDL, FKs and statuses with new ownership migrations applied twice in disposable PostgreSQL 15, 2 CPU / 1GiB. Unrelated actor/restaurant/event parents are minimal fixtures. Concurrent independent DB sessions; no vendor calls.','results':results,'expired_misa':'manual_action_required, one event, zero reclaims','rotated_token':'remains enabled','authenticated_claim':'denied','token_refresh_winners':1,'token_refresh_contenders':8,'deferred_publish_attempts':0,'legacy_completion_owned_updates':0,'expired_emergency_old_owner_updates':0,'current_unregistered_token':'disabled','sepay_windows_polling':{'deliveries':1,'push_dispatch_required':False,'duplicate':'duplicate'}},indent=2))
 print('DISPATCH_OWNERSHIP_SQL=PASS')
except subprocess.CalledProcessError as e:print(e.output);raise
finally:subprocess.run(['docker','rm','-f',name],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
