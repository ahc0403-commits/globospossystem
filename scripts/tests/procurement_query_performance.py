"""EXPLAIN the demand query itself: function-boundary EXPLAIN hides nested plans."""
import json, pathlib, subprocess, sys
port, root = sys.argv[1:3]
cmd=['psql','-X','-h','127.0.0.1','-p',port,'-d','postgres','-v','ON_ERROR_STOP=1','-Atq']
def sql(value):
    return subprocess.run(cmd,input=value,text=True,capture_output=True,check=True).stdout.strip()
source=(pathlib.Path(root)/'supabase/migrations/20261005033000_procurement_set_based_evidence.sql').read_text()
a=source.index('WITH products AS MATERIALIZED');b=source.index(');\nEND $$;',a)
query=source[a:b].replace('p_store_id',"'00000000-0000-4000-8000-000000000101'::uuid").replace('fresh_hours','24').replace("actor->>'can_view_prices'","'true'")
def walk(plan):
    yield plan
    for child in plan.get('Plans',[]):yield from walk(child)
results=[]
for count in [100,1000,10000]:
    seed=f"""BEGIN;
INSERT INTO public.inventory_transactions(restaurant_id,ingredient_id,transaction_type,quantity_g,created_at)
SELECT test_uuid(101),test_uuid(501),'deduct',1,((now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date-1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh' FROM generate_series(1,{count});
EXPLAIN (ANALYZE,BUFFERS,FORMAT JSON) {query};
ROLLBACK;"""
    plan=json.loads(sql(seed))[0]
    scans=[p for p in walk(plan['Plan']) if p.get('Relation Name')=='inventory_transactions']
    assert scans and all(p.get('Actual Loops',0)==1 for p in scans), 'Usage must be scanned once, not per product'
    assert not any(p.get('Subplan Name','').startswith('SubPlan') for p in walk(plan['Plan'])), 'Demand aggregates must not be correlated per product'
    assert plan['Execution Time']<1500,'Unexpected demand-query regression in the isolated fixture'
    results.append({'usage_rows':count,'execution_ms':plan['Execution Time'],'usage_scan_loops':[p['Actual Loops'] for p in scans],'shared_hit_blocks':plan['Plan'].get('Shared Hit Blocks',0)})
output=pathlib.Path('/tmp/procurement-query-performance-20261005.json');output.write_text(json.dumps(results,indent=2))
print('PASS: demand EXPLAIN ANALYZE/BUFFERS at 100/1000/10000 rows: '+json.dumps(results))

# Supplier, batch snapshot and bounded page plans are measured independently.
supplier_source=source[source.index(' WITH suppliers AS'):source.index(' INTO result FROM suppliers')]
supplier_query=(supplier_source+source[source.index(' FROM suppliers s'):source.index(';\n RETURN result||')]).replace('p_store_id',"test_uuid(101)")
snapshot_query=source[source.index('WITH orders AS MATERIALIZED'):source.index(');\nEND $$;',source.index('WITH orders AS MATERIALIZED'))]
snapshot_query=snapshot_query.replace('p_order_ids','ARRAY(SELECT test_uuid(500000+n) FROM generate_series(1,50) n)').replace('p_store_ids','ARRAY[test_uuid(101)]')
page_source=(pathlib.Path(root)/'supabase/migrations/20261005040000_procurement_read_indexes.sql').read_text()
page_start=page_source.index('WITH page AS MATERIALIZED')
page_query=page_source[page_start:page_source.index(');\nEND $$;',page_start)]
for parameter,value in [('p_store_ids','ARRAY[test_uuid(101)]'),('p_before_id','NULL::uuid'),('p_before','NULL::timestamptz'),('p_status','NULL::text'),('p_limit','20')]:
    page_query=page_query.replace(parameter,value)

read_results=[]
for count in [100,1000,10000]:
    seed=f"""SET request.jwt.claim.role='service_role';SET app.procurement_write='true';
INSERT INTO public.inventory_suppliers(id,supplier_name) SELECT test_uuid(490000+n),'Bench supplier '||n FROM generate_series(1,20) n;
INSERT INTO public.inventory_supplier_items(supplier_id,product_id,order_unit,order_unit_quantity_base) SELECT test_uuid(490000+n),test_uuid(301),'ea',1 FROM generate_series(1,20) n;
INSERT INTO public.inventory_purchase_orders(id,purchase_order_no,restaurant_id,supplier_id,status,workflow_version,procurement_status,commercial_terms,requested_delivery_date)
 SELECT test_uuid(500000+n),'BENCH-'||n,test_uuid(101),test_uuid(490001+(n%20)),'ordered',2,'confirmed','{{"approval_policy_version":2}}',current_date FROM generate_series(1,{count}) n;
INSERT INTO public.inventory_purchase_order_lines(id,purchase_order_id,product_id,ordered_quantity_base,ordered_quantity_unit,order_unit,unit_price,order_unit_quantity_base_snapshot,tax_rate_snapshot)
 SELECT test_uuid(600000+n),test_uuid(500000+n),test_uuid(301),1,1,'ea',100,1,0 FROM generate_series(1,{count}) n;
INSERT INTO public.inventory_receipts(id,purchase_order_id,restaurant_id,supplier_id,status)
 SELECT test_uuid(700000+n),test_uuid(500000+n),test_uuid(101),test_uuid(490001+(n%20)),'confirmed' FROM generate_series(1,{count}) n;
INSERT INTO public.inventory_receipt_lines(id,receipt_id,purchase_order_line_id,product_id,received_quantity_base,accepted_quantity_base,actual_unit_price)
 SELECT test_uuid(800000+n),test_uuid(700000+n),test_uuid(600000+n),test_uuid(301),1,1,100 FROM generate_series(1,{count}) n;
ANALYZE public.inventory_purchase_orders;ANALYZE public.inventory_purchase_order_lines;ANALYZE public.inventory_receipts;ANALYZE public.inventory_receipt_lines;
"""
    # Each query sees an identical rolled-back fixture. Includes internal plans, not only the RPC function boundary.
    for name,query in [('supplier',supplier_query),('snapshot_50',snapshot_query),('page_20',page_query)]:
        plan=json.loads(sql('BEGIN;'+seed+f'EXPLAIN (ANALYZE,BUFFERS,FORMAT JSON) {query};ROLLBACK;'))[0]
        if True:
            assert not any(p.get('Subplan Name','').startswith('SubPlan') for p in walk(plan['Plan'])),f'{name}: no correlated relation-wide SubPlan'
        plan_path=pathlib.Path('/tmp/procurement-explain-20261005');plan_path.mkdir(exist_ok=True)
        (plan_path/f'{name}_{count}.json').write_text(json.dumps(plan,indent=2))
        # Ten DB execution samples in the same fixture; network timing is not represented.
        samples=[]
        payload_bytes=None
        for repeat in range(10):
            output=sql('BEGIN;'+seed+f'EXPLAIN (ANALYZE,BUFFERS,FORMAT JSON) {query};ROLLBACK;')
            samples.append(json.loads(output)[0]['Execution Time'])
        payload_bytes=int(sql('BEGIN;'+seed+f'SELECT octet_length(({query})::text);ROLLBACK;'))
        ordered=sorted(samples)
        read_results.append({'path':name,'history_orders':count,'returned_parent_limit':50 if name=='snapshot_50' else 20 if name=='page_20' else 20,
            'payload_bytes':payload_bytes,'db_p50_ms':(ordered[4]+ordered[5])/2,'db_p95_ms':ordered[-1],
            'db_plan_ms':plan['Execution Time'],'shared_hit_blocks':plan['Plan'].get('Shared Hit Blocks',0),'sample_count':10,
            'api_contract_read_calls':1,'measurement':'local DB execution; p95 nearest-rank, transport excluded'})
        assert max(samples)<1500, f'{name}: isolated local regression budget exceeded'
        assert payload_bytes<1_500_000,f'{name}: bounded fixture payload grew unexpectedly'
# Parent page payload does not include total history; snapshot fixed 50 parents also stays fixed.
for name in ['page_20','snapshot_50']:
    sizes=[r['payload_bytes'] for r in read_results if r['path']==name]
    assert max(sizes)/min(sizes)<1.10, f'{name}: payload must not grow with unselected history'
pathlib.Path('/tmp/procurement-read-performance-20261005.json').write_text(json.dumps(read_results,indent=2))
print('PASS: supplier/snapshot/page plans and fixed payloads at 100/1000/10000 orders: '+json.dumps(read_results))
