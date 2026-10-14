"""Measure new inbox internals in the disposable DB; no production auth/network."""
import json,pathlib,subprocess,sys,time
port,root=sys.argv[1:3]
cmd=['psql','-X','-h','127.0.0.1','-p',port,'-d','postgres','-v','ON_ERROR_STOP=1','-Atq']
source=(pathlib.Path(root)/'supabase/migrations/20261014080000_procurement_approval_inbox.sql').read_text()
a=source.index(' WITH scopes AS MATERIALIZED');b=source.index(' INTO result;',a)
query=source[a:b].replace('p_scopes',"(SELECT jsonb_agg(jsonb_build_object('store_id',id,'brand_id',brand_id,'tax_entity_id',tax_entity_id,'actor',jsonb_build_object('system','office','subject_id',test_uuid(170001),'store_id',id,'can_read',true,'can_office_approve',true,'can_view_prices',true))) FROM public.restaurants WHERE id IN(SELECT test_uuid(160000+n) FROM generate_series(1,STORE_COUNT) n))").replace('p_query',"'{}'::jsonb").replace('lim','50')
def run(value):
 result=subprocess.run(cmd,input=value,text=True,capture_output=True)
 if result.returncode:
  raise RuntimeError(result.stderr)
 return result.stdout.strip()
def walk(plan):
 yield plan
 for child in plan.get('Plans',[]):yield from walk(child)
results=[]
for stores in [2,20,100]:
 for count in [100,1000,10000]:
  seed=f"""SET request.jwt.claim.role='service_role';SET app.procurement_write='true';
INSERT INTO public.restaurants(id,brand_id,tax_entity_id,name) SELECT test_uuid(160000+n),r.brand_id,r.tax_entity_id,'Inbox fixture '||n FROM generate_series(1,{stores}) n CROSS JOIN public.restaurants r WHERE r.id=test_uuid(101);
INSERT INTO public.procurement_store_policies(restaurant_id,enabled,two_stage_required) SELECT test_uuid(160000+n),true,true FROM generate_series(1,{stores}) n;
INSERT INTO public.inventory_purchase_requests(id,restaurant_id,source,requested_delivery_date,reason,created_actor,status,approval_policy_version,submitted_at,store_approved_at,store_approved_actor)
 SELECT test_uuid(180000+n),test_uuid(160001+(n%{stores})),'pos',current_date,'Inbox benchmark',jsonb_build_object('system','pos','subject_id',test_uuid(1)),'office_review',3,now()-interval '90 days'+n*interval '1 second',now(),jsonb_build_object('system','pos','subject_id',test_uuid(2)) FROM generate_series(1,{count}) n;
ANALYZE public.inventory_purchase_requests;
"""
  sql=query.replace('STORE_COUNT',str(stores))
  plan=json.loads(run('BEGIN;'+seed+'EXPLAIN(ANALYZE,BUFFERS,FORMAT JSON) '+sql+';ROLLBACK;'))[0]
  scans=[p for p in walk(plan['Plan']) if p.get('Relation Name')=='inventory_purchase_requests']
  pathlib.Path('/tmp/procurement-inbox-last-plan.json').write_text(json.dumps(plan,indent=2))
  assert scans and all(p.get('Actual Loops',0)==1 for p in scans),'PR relation must not be rescanned per store/request'
  payload=json.loads(run('BEGIN;'+seed+sql+';ROLLBACK;'))
  assert len(payload['requests'])==50 and payload['approval_counts']['pending']==count
  assert plan['Execution Time']<2000,'Inbox local regression budget exceeded'
  results.append({'stores':stores,'requests':count,'db_execution_ms':plan['Execution Time'],'returned_rows':50,'api_rpc_calls':1,'request_scan_loops':[p['Actual Loops'] for p in scans]})
output=pathlib.Path('/tmp/procurement-inbox-performance-20261014.json');output.write_text(json.dumps(results,indent=2))
print('PASS: new inbox EXPLAIN at 2/20/100 stores and 100/1000/10000 PRs: '+json.dumps(results))
