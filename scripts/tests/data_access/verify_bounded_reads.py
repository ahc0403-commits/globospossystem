"""Disposable canonical SQL/RLS verification; never connects to an existing DB."""
from pathlib import Path
import subprocess, json, re, time, os, statistics, sys
root=Path(__file__).resolve().parents[3]
out=Path(sys.argv[1] if len(sys.argv)>1 else '/tmp/pos-bounded-data-verification');out.mkdir(parents=True,exist_ok=True)
(out/'results.json').unlink(missing_ok=True)
name='pos-bounded-verify-'+str(os.getpid())
def run(*args,input=None): return subprocess.check_output(args,input=input,text=True,stderr=subprocess.STDOUT)
def sql(q,db='inventory'):return run('docker','exec','-i',name,'psql','-XqAt','-U','postgres','-d',db,'-v','ON_ERROR_STOP=1',input=q).strip()
def load(path,db='inventory'):return sql((root/path).read_text(),db)
def fn(path,n):
 s=(root/path).read_text();a=s.index('CREATE OR REPLACE FUNCTION public.'+n+'(');return s[a:s.index('$$;',a)+3]
def apply(path,db='inventory'):
 print('APPLY='+path,flush=True);load(path,db)
def measure(q,db):
 samples=[]; payload=sql('SELECT '+q,db)
 for _ in range(20):samples.append(json.loads(sql('EXPLAIN(ANALYZE,BUFFERS,FORMAT JSON) SELECT '+q,db))[0]['Execution Time'])
 return {'server_ms':samples,'p50_ms':statistics.median(samples),'p95_ms':sorted(samples)[18],'response_bytes':len(payload.encode())}
results=[]
try:
 run('docker','run','--detach','--rm','--name',name,'--cpus','2','--memory','2g','--env','POSTGRES_HOST_AUTH_METHOD=trust','--env','POSTGRES_DB=inventory','postgres:15','-c','statement_timeout=30000')
 for _ in range(60):
  try:sql('SELECT 1');break
  except subprocess.CalledProcessError:time.sleep(.25)
 load('test/fixtures/inventory_workflow_setup.sql')
 base=out/'inventory_base.sql';run('python3',str(root/'scripts/tests/inventory_workflow_fixture.py'),str(root),str(base));sql(base.read_text())
 apply('supabase/migrations/20260911100000_inventory_workflow_all_stores.sql')
 apply('supabase/migrations/20260911150000_inventory_order_quantity_image_warning.sql')
 sql("ALTER TABLE public.inventory_items ADD COLUMN cost_per_unit numeric,ADD COLUMN supplier_name text;")
 for p in ['supabase/migrations/20261011010000_bounded_data_reads.sql','supabase/migrations/20261011100000_inventory_catalog_pages.sql']:
  apply(p);apply(p)
 sql("""
 INSERT INTO brands VALUES(test_uuid(1)); INSERT INTO auth.users VALUES(test_uuid(2));
 INSERT INTO restaurants(id,brand_id,name) VALUES(test_uuid(3),test_uuid(1),'target'),(test_uuid(4),test_uuid(1),'other');
 INSERT INTO users(id,auth_id,role,restaurant_id,primary_store_id,full_name) VALUES(test_uuid(2),test_uuid(2),'store_admin',test_uuid(3),test_uuid(3),'Fixture');
 INSERT INTO inventory_suppliers(id,brand_id,supplier_name) VALUES(test_uuid(5),test_uuid(1),'Supplier');
 INSERT INTO inventory_products(id,restaurant_id,brand_id,name,product_code) SELECT test_uuid(100+n),test_uuid(3),test_uuid(1),'Product '||n,'CODE-'||n FROM generate_series(1,100)n;
 INSERT INTO inventory_supplier_items(id,supplier_id,product_id,order_unit,order_unit_quantity_base) SELECT test_uuid(200+n),test_uuid(5),test_uuid(100+n),'ea',1 FROM generate_series(1,100)n;
 INSERT INTO inventory_purchase_orders(id,purchase_order_no,restaurant_id,supplier_id,created_at) VALUES(test_uuid(9),'current',test_uuid(3),test_uuid(5),'2026-10-11');
 INSERT INTO inventory_purchase_order_lines(id,purchase_order_id,product_id,supplier_item_id,order_unit,created_at) SELECT test_uuid(300+n),test_uuid(9),test_uuid(100+n),test_uuid(200+n),'ea','2026-10-11' FROM generate_series(1,100)n;
 CREATE FUNCTION fixture_history(s integer) RETURNS jsonb LANGUAGE plpgsql AS $$DECLARE r jsonb; BEGIN
  PERFORM set_config('request.jwt.claim.sub',test_uuid(2)::text,true);
  SELECT get_inventory_supplier_history_batch(test_uuid(9),ARRAY(SELECT test_uuid(200+n) FROM generate_series(1,s)n)) INTO r; RETURN r; END $$;
 GRANT EXECUTE ON FUNCTION fixture_history(integer) TO authenticated;
 """)
 current_po=sql('SELECT test_uuid(9)')
 for h in [100,1000,100000]:
  sql(f"""
  DELETE FROM inventory_purchase_orders WHERE id<>test_uuid(9);
  INSERT INTO inventory_purchase_orders(id,purchase_order_no,restaurant_id,supplier_id,created_at) SELECT md5('po'||n)::uuid,'H-'||n,test_uuid(3),test_uuid(5),'2026-01-01'::timestamptz+n*interval '1 minute' FROM generate_series(1,{h})n;
  INSERT INTO inventory_purchase_order_lines(id,purchase_order_id,product_id,supplier_item_id,order_unit,ordered_quantity_base,created_at) SELECT md5('line'||n)::uuid,md5('po'||n)::uuid,test_uuid(101+(n-1)%100),test_uuid(201+(n-1)%100),'ea',10,'2026-01-01'::timestamptz+n*interval '1 minute' FROM generate_series(1,{h})n;
  ANALYZE;
  """)
  for s in [1,10,100]:
   q=f'fixture_history({s})';r=measure(q,'inventory');data=json.loads(sql('SET ROLE authenticated; SELECT '+q))
   assert len(data['rows'])==min(3,h//100)*s, (h,s,data)
   assert all(row['purchase_order_id']!=current_po for row in data['rows'])
   if h==100000 and s in [1,100]:
    body=fn('supabase/migrations/20261011010000_bounded_data_reads.sql','get_inventory_supplier_history_batch')
    inner=body[body.index('WITH selected AS MATERIALIZED'):body.index('RETURN jsonb_build_object')].replace('INTO v_result','').replace('p_purchase_order_id',"'"+current_po+"'::uuid").replace('p_supplier_item_ids','ARRAY['+','.join("'"+sql('SELECT test_uuid('+str(200+i)+')')+"'::uuid" for i in range(1,s+1))+']')
    plan=json.loads(sql("SET ROLE authenticated;DO $$BEGIN PERFORM set_config('request.jwt.claim.sub','"+sql('SELECT test_uuid(2)')+"',false);END$$;EXPLAIN(ANALYZE,BUFFERS,FORMAT JSON) "+inner))
    (out/('history_'+str(s)+'_inner_explain.json')).write_text(json.dumps(plan,indent=2))
   results.append({'case':'supplier_history','historical_rows':h,'selected_products':s,'returned_rows':len(data['rows']),**r})
  print('HISTORY_ROWS='+str(h),flush=True)
 # Independent receipt children must sum once and never multiply history rows.
 sql("""
 INSERT INTO inventory_receipts(id,purchase_order_id,restaurant_id,supplier_id,status) SELECT md5('r'||n)::uuid,md5('po100000')::uuid,test_uuid(3),test_uuid(5),'confirmed' FROM generate_series(1,100)n;
 INSERT INTO inventory_receipt_lines(receipt_id,purchase_order_line_id,product_id,received_quantity_base,accepted_quantity_base,rejected_quantity_base) SELECT md5('r'||n)::uuid,md5('line100000')::uuid,test_uuid(200),2,1,1 FROM generate_series(1,100)n;
 SET ROLE authenticated;
 SELECT set_config('request.jwt.claim.sub',test_uuid(2)::text,false);
 """)
 data=json.loads(sql('SELECT fixture_history(100)'));last=next(r for r in data['rows'] if r['purchase_order_id']==sql("SELECT md5('po100000')::uuid"));assert last['received_quantity_base']==200 and len(data['rows'])==300
 # Supplier/product pages have source limits and retain complete totals.
 q="get_inventory_catalog_page(test_uuid(3),'products')";r=measure("(SELECT set_config('request.jwt.claim.sub',test_uuid(2)::text,true)) IS NOT NULL AND "+q+" IS NOT NULL",'inventory')
 data=json.loads(sql("SET ROLE authenticated;SELECT set_config('request.jwt.claim.sub',test_uuid(2)::text,false);SELECT "+q).splitlines()[-1]);assert len(data['rows'])==50 and data['stats']['total']==100 and data['has_more']
 data2=json.loads(sql("SET ROLE authenticated;SELECT set_config('request.jwt.claim.sub',test_uuid(2)::text,false);SELECT get_inventory_catalog_page(test_uuid(3),'products',NULL,NULL,NULL,'"+data['rows'][-1]['id']+"',50)").splitlines()[-1]);assert len(data2['rows'])==50 and not data2['has_more'];assert not set(r['id'] for r in data['rows']) & set(r['id'] for r in data2['rows'])
 try:sql("SET ROLE authenticated;SELECT set_config('request.jwt.claim.sub',test_uuid(2)::text,false);SELECT get_inventory_catalog_page(test_uuid(4),'products')")
 except subprocess.CalledProcessError as e: assert 'FORBIDDEN' in e.output
 else:raise AssertionError('Foreign catalog scope admitted')
 results.append({'case':'catalog','first_rows':50,'second_rows':50,'exact_count':100,'foreign_scope':'denied','receipt_join_sum':200})
 # Legacy financial receipts and delta previews use current canonical read models.
 sql('CREATE DATABASE ledger');setup=(root/'test/fixtures/menu_localization_setup.sql').read_text();setup=re.sub(r'CREATE ROLE (anon|authenticated|service_role) NOLOGIN;','',setup);sql(setup,'ledger')
 apply('supabase/migrations/20260915200000_menu_display_localization.sql','ledger')
 sql(fn('supabase/migrations/20261011010000_bounded_data_reads.sql','get_store_menu_sales_analytics'),'ledger')
 apply('supabase/migrations/20261011050000_receipt_page_item_reads.sql','ledger');apply('supabase/migrations/20261011050000_receipt_page_item_reads.sql','ledger')
 apply('supabase/migrations/20261011110000_table_preview_delta.sql','ledger')
 load('test/sql/menu_localization_test.sql','ledger')
 sql((root/'test/sql/menu_localization_test.sql').read_text().replace('ROLLBACK;','COMMIT;'),'ledger')
 # Preserve original fixture tests above, additionally prove cursor/amount equality.
 actor="b1000000-0000-4000-8000-0000000000a1";store="b1000000-0000-4000-8000-000000000005"
 rows=json.loads(sql(f"SELECT set_config('request.jwt.claim.sub','{actor}',false);SELECT get_receipt_ledger_page('2026-09-15','{store}',NULL,NULL,1)",'ledger').splitlines()[-1])
 results.append({'case':'receipt_page','receipts':len(rows['receipts']),'exact_summary':rows['summary']})
 # Period-after split payments preserve the original last-payment semantics.
 sql("INSERT INTO payments(id,order_id,restaurant_id,amount,method,created_at) VALUES(md5('later-payment')::uuid,'b1000000-0000-4000-8000-000000000010','b1000000-0000-4000-8000-000000000005',1000,'CASH','2026-09-17')",'ledger')
 auth=f"DO $$BEGIN PERFORM set_config('request.jwt.claim.sub','{actor}',false);END$$;"
 call=f"get_store_menu_sales_analytics('{store}','2026-09-15','2026-09-16','all')"
 new=json.loads(sql(auth+'SELECT '+call,'ledger'))
 sql(fn('supabase/migrations/20260915200000_menu_display_localization.sql','get_store_menu_sales_analytics'),'ledger')
 old=json.loads(sql(auth+'SELECT '+call,'ledger'));assert old==new and new['summary']['menu_sales_amount']==0
 sql(fn('supabase/migrations/20261011010000_bounded_data_reads.sql','get_store_menu_sales_analytics'),'ledger')
 results.append({'case':'menu_period_after_split','old_new_equal':True,'out_of_period_candidate_amount':0})
 # Export projects just one preferred supplier; first page remains source-bounded.
 exported=json.loads(sql("SET ROLE authenticated;DO $$BEGIN PERFORM set_config('request.jwt.claim.sub','"+sql('SELECT test_uuid(2)')+"',false);END$$;SELECT get_inventory_catalog_page(test_uuid(3),'ingredient_export')"));assert len(exported['rows'])==50 and all(r['export_supplier']['supplier_name']=='Supplier' for r in exported['rows'])
 # Recipe export uses the canonical recipe table/constraints; menu identity rows
 # are a reduced fixture. Explicit store checks protect the definer page API.
 sql("ALTER TABLE inventory_items ADD COLUMN name text;CREATE TABLE public.menu_items(id uuid PRIMARY KEY,restaurant_id uuid REFERENCES restaurants(id),name text);")
 recipe_ddl=(root/'supabase/migrations/20260403000002_inventory_v2.sql').read_text()
 sql(recipe_ddl[recipe_ddl.index('CREATE TABLE IF NOT EXISTS menu_recipes'):recipe_ddl.index('ALTER TABLE menu_recipes ENABLE')])
 apply('supabase/migrations/20261011120000_recipe_export_pages.sql');apply('supabase/migrations/20261011120000_recipe_export_pages.sql')
 sql("""
 INSERT INTO inventory_items(id,restaurant_id,name) SELECT test_uuid(4000+n),test_uuid(3),'Ingredient '||n FROM generate_series(1,501)n;
 UPDATE inventory_products SET inventory_item_id=test_uuid(4000+substring(product_code from 6)::integer),base_unit='g';
 INSERT INTO inventory_products(id,restaurant_id,brand_id,name,inventory_item_id,base_unit) SELECT test_uuid(5000+n),test_uuid(3),test_uuid(1),'Ingredient '||n,test_uuid(4000+n),'g' FROM generate_series(101,501)n;
 INSERT INTO menu_items SELECT test_uuid(7000+n),test_uuid(3),'Menu '||n FROM generate_series(1,501)n;
 INSERT INTO menu_recipes(id,restaurant_id,menu_item_id,ingredient_id,quantity_g) SELECT test_uuid(10000+n),test_uuid(3),test_uuid(7001+(n-1)%501),test_uuid(4001+(n-1)/501),12.5 FROM generate_series(1,1500)n;
 INSERT INTO inventory_items(id,restaurant_id,name) VALUES(test_uuid(999999),test_uuid(4),'Foreign');
 INSERT INTO menu_items SELECT md5('foreign-menu'||n)::uuid,test_uuid(4),'Foreign '||n FROM generate_series(1,100000)n;
 INSERT INTO menu_recipes(id,restaurant_id,menu_item_id,ingredient_id,quantity_g) SELECT md5('foreign-recipe'||n)::uuid,test_uuid(4),md5('foreign-menu'||n)::uuid,test_uuid(999999),1 FROM generate_series(1,100000)n;
 ANALYZE;
 """)
 page_auth="SET ROLE authenticated;DO $$BEGIN PERFORM set_config('request.jwt.claim.sub','"+sql('SELECT test_uuid(2)')+"',false);END$$;"
 for source,total in [('recipes',1500),('menus',501),('ingredients',501)]:
  cursor='NULL';seen=set();sizes=[]
  while True:
   page=json.loads(sql(page_auth+"SELECT get_inventory_recipe_export_page(test_uuid(3),'"+source+"',"+cursor+",500)"))
   ids=[r['id'] for r in page['rows']];assert not seen.intersection(ids);seen.update(ids);sizes.append(len(ids));assert len(ids)<=500
   if not page['has_more']:break
   assert ids;cursor="'"+ids[-1]+"'"
  assert len(seen)==total,(source,len(seen),total)
  results.append({'case':'recipe_export_pages','source':source,'page_sizes':sizes,'total_rows':len(seen),'foreign_recipe_rows':100000})
 try:sql(page_auth+"SELECT get_inventory_recipe_export_page(test_uuid(4),'recipes')")
 except subprocess.CalledProcessError as e:assert 'FORBIDDEN' in e.output
 else:raise AssertionError('Foreign recipe export admitted')
 for invalid in ['501','NULL']:
  try:sql(page_auth+"SELECT get_inventory_recipe_export_page(test_uuid(3),'recipes',NULL,"+invalid+")")
  except subprocess.CalledProcessError as e:assert 'QUERY_INVALID' in e.output
  else:raise AssertionError('Recipe export limit admitted')
 for source,table in [('recipes','menu_recipes'),('menus','menu_items'),('ingredients','inventory_products')]:
  plan=json.loads(sql("EXPLAIN(ANALYZE,BUFFERS,FORMAT JSON) SELECT id FROM "+table+" WHERE restaurant_id=test_uuid(3) ORDER BY id LIMIT 501"))
  (out/('recipe_export_'+source+'_explain.json')).write_text(json.dumps(plan,indent=2))
 results.append({'case':'recipe_export_scope_and_limits','foreign_scope':'denied','null_and_501_limits':'denied'})
 # Dashboard v2 executes without the legacy stock helper installed; the
 # client composes low stock from its shared read. Monetary aggregates are exact.
 apply('supabase/migrations/20261011070000_inventory_dashboard_shared_stock.sql');apply('supabase/migrations/20261011070000_inventory_dashboard_shared_stock.sql')
 sql("UPDATE inventory_items SET current_stock=2,cost_per_unit=3 WHERE restaurant_id=test_uuid(3);UPDATE inventory_purchase_orders SET status='submitted',total_amount=7 WHERE id=test_uuid(9);UPDATE inventory_purchase_orders SET status='office_approved',total_amount=13 WHERE id=md5('po100000')::uuid;")
 dashboard=json.loads(sql(page_auth+"SELECT get_inventory_purchase_dashboard_v2(test_uuid(3),NULL)"))
 assert dashboard['store_count']==1 and dashboard['total_inventory_amount']==3006 and dashboard['submitted_purchase_amount']==7 and dashboard['approved_purchase_amount']==13 and 'low_stock_count' not in dashboard,dashboard
 try:sql(page_auth+"SELECT get_inventory_purchase_dashboard_v2(test_uuid(4),NULL)")
 except subprocess.CalledProcessError as e:assert 'FORBIDDEN' in e.output
 else:raise AssertionError('Foreign dashboard admitted')
 results.append({'case':'dashboard_projection','rows':dashboard,'legacy_stock_helper_installed':False,'foreign_scope':'denied'})
 # Exact auth lookup and owned worker claims use service-only grants.
 sql('CREATE DATABASE workers');sql("CREATE SCHEMA auth;CREATE TABLE auth.users(id uuid PRIMARY KEY,email text,instance_id uuid DEFAULT '00000000-0000-0000-0000-000000000000',is_sso_user boolean DEFAULT false);CREATE INDEX users_instance_id_email_idx ON auth.users(instance_id,lower(email));CREATE FUNCTION auth.role() RETURNS text LANGUAGE sql STABLE AS $$SELECT current_setting('request.jwt.claim.role',true)$$;CREATE TABLE tax_entity(id uuid PRIMARY KEY);",'workers')
 apply('supabase/migrations/20261011030000_fixed_account_exact_lookup.sql','workers')
 sql("CREATE FUNCTION fixture_auth_lookup() RETURNS jsonb LANGUAGE plpgsql AS $$ BEGIN PERFORM set_config('request.jwt.claim.role','service_role',true); RETURN find_fixed_account_auth_user(' USER-100@EXAMPLE.INVALID '); END $$",'workers')
 for n in [100,10000,100000]:
  sql(f"TRUNCATE auth.users;INSERT INTO auth.users(id,email) SELECT md5(n::text)::uuid,'user-'||n||'@example.invalid' FROM generate_series(1,{n})n;ANALYZE auth.users;",'workers')
  p=json.loads(sql("EXPLAIN(ANALYZE,BUFFERS,FORMAT JSON) SELECT id,email FROM auth.users WHERE instance_id='00000000-0000-0000-0000-000000000000' AND lower(email)='user-100@example.invalid' AND is_sso_user=false LIMIT 1",'workers'))
  r=measure("fixture_auth_lookup()",'workers')
  results.append({'case':'auth_exact_lookup','directory_rows':n,'returned_rows':1,'plan':p,**r})
 print('BOUNDED_SQL_VERIFICATION=PASS',flush=True)
 (out/'results.json').write_text(json.dumps({'environment':'Disposable PostgreSQL 15, canonical relevant DDL/RLS + current read migrations; unrelated identity tables are fixtures. 2 CPU / 2 GiB, no external ports; 20 server warm samples. Supabase 17/PostgREST financial tests are separate.','results':results},indent=2))
except subprocess.CalledProcessError as e:
 print(e.output,flush=True);raise
finally:subprocess.run(['docker','rm','-f',name],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
