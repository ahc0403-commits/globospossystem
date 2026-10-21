"""Measure only the owned database created by corporate_sales_export_sql_test.sh."""
from pathlib import Path
import concurrent.futures
import json
import os
import statistics
import subprocess
import sys
import time

container, output = sys.argv[1:3]
assert container.startswith('pos-report-ready-test-')
workers = int(os.environ.get('GLOBOS_DEPOSIT_PERF_CONCURRENCY', '20'))
assert 1 <= workers <= 20
def sql(query):
    result = subprocess.run(['docker','exec','-i',container,'psql','-X','-qAt','-v','ON_ERROR_STOP=1','-U','postgres','-d','report_ready_test'],input=query,text=True,capture_output=True,timeout=180)
    if result.returncode:
        raise RuntimeError(result.stderr)
    return result.stdout.strip()

def nested_plans():
    plans=[]
    # The owned Supabase image blocks auto_explain. Explain the exact query
    # bodies directly, including the two SQL readers invoked by the summary.
    for signature in ['get_pos_daily_sales_summary(date,boolean)', 'pos_daily_receipt_scope(date)', 'pos_photo_receipt_rows(date)']:
        body=sql(f"SELECT prosrc FROM pg_proc WHERE oid='public.{signature}'::regprocedure")
        if signature.startswith('get_pos_daily'):
            body=body[body.index('WITH revisions'):body.index(' RETURN jsonb_build_object')]
            body=body.replace(' INTO result FROM',' FROM')
        body=body.replace('p_business_date',"DATE '2026-10-02'").replace('p_include_export_metadata','false')
        plan=json.loads(sql("EXPLAIN (ANALYZE,BUFFERS,FORMAT JSON) "+body))[0]
        plan['explained_function']=signature
        plans.append(plan)
    scans=[]
    def visit(node):
        if node.get('Relation Name'):
            scans.append({'relation':node['Relation Name'],'scan':node['Node Type'],
                          'rows_examined':(node.get('Actual Rows',0)+node.get('Rows Removed by Filter',0))*node.get('Actual Loops',0),
                          'shared_hit_blocks':node.get('Shared Hit Blocks',0),'shared_read_blocks':node.get('Shared Read Blocks',0)})
        for child in node.get('Plans',[]): visit(child)
    for plan in plans: visit(plan['Plan'])
    return {'scan_rows_examined_including_repeated_scans':sum(s['rows_examined'] for s in scans),
            'relation_scans':scans,'plans':plans}

results=[]
for stores in (5,50,500):
    sql(f"""
    SET statement_timeout='120s';
    DELETE FROM order_items WHERE order_id IN(SELECT id FROM orders WHERE id IN(SELECT md5('deposit-scale-order-'||i)::uuid FROM generate_series(1,100000) i));
    DELETE FROM payments WHERE restaurant_id IN(SELECT md5('deposit-scale-store-'||i)::uuid FROM generate_series(1,500) i);
    DELETE FROM daily_closings WHERE restaurant_id IN(SELECT md5('deposit-scale-store-'||i)::uuid FROM generate_series(1,500) i);
    DELETE FROM orders WHERE id IN(SELECT md5('deposit-scale-order-'||i)::uuid FROM generate_series(1,100000) i);
    DELETE FROM restaurants WHERE id IN(SELECT md5('deposit-scale-store-'||i)::uuid FROM generate_series(1,500) i);
    INSERT INTO tax_entity VALUES('19000000-0000-0000-0000-000000000001','DEPOSIT-SCALE','Synthetic deposit scale') ON CONFLICT DO NOTHING;
    INSERT INTO restaurants(id,name,brand_id,tax_entity_id,is_active)
    SELECT md5('deposit-scale-store-'||i)::uuid,'Scale store '||i,'a3bbff2e-a6f7-4c19-b2bd-410ec9a4f878','19000000-0000-0000-0000-000000000001',true FROM generate_series(1,{stores}) i;
    INSERT INTO orders SELECT md5('deposit-scale-order-'||i)::uuid,'completed','dine_in' FROM generate_series(1,{stores*200}) i;
    INSERT INTO payments(id,order_id,restaurant_id,created_at,amount_portion,amount,method,is_revenue)
    SELECT md5('deposit-scale-payment-'||i)::uuid,md5('deposit-scale-order-'||i)::uuid,md5('deposit-scale-store-'||(((i-1)/200)+1))::uuid,'2026-10-02 12:00+07',10800,10800,'CASH',true FROM generate_series(1,{stores*200}) i;
    INSERT INTO order_items(id,order_id,quantity,unit_price,total_amount_ex_tax,vat_rate,vat_amount,paying_amount_inc_tax,created_at,status,is_service_item,item_type)
    SELECT md5('deposit-scale-item-'||i)::uuid,md5('deposit-scale-order-'||i)::uuid,1,10000,10000,8,800,10800,'2026-10-02 12:00+07','served',false,'menu_item' FROM generate_series(1,{stores*200}) i;
    INSERT INTO daily_closings(restaurant_id,closing_date,close_source,counted_cash_amount,opening_cash_amount,payments_cash,payments_total,expected_cash_amount,cash_variance)
    SELECT id,'2026-10-02','manual',7160000,5000000,2160000,2160000,7160000,0 FROM restaurants WHERE id IN(SELECT md5('deposit-scale-store-'||i)::uuid FROM generate_series(1,{stores}) i);
    ANALYZE; SELECT pg_stat_reset();
    """)
    def query(actor=1):
        started=time.perf_counter()
        data=sql(f"""
        SET statement_timeout='120s'; SET work_mem='16MB'; SET fixture.super_admin='true';
        SET request.jwt.claim.sub='00000000-0000-0000-0000-{actor:012d}';
        WITH tick AS MATERIALIZED(SELECT clock_timestamp() t), payload AS MATERIALIZED(SELECT get_pos_daily_sales_summary('2026-10-02',false) data FROM tick)
        SELECT jsonb_build_object('server_ms',extract(epoch FROM clock_timestamp()-tick.t)*1000,'response_bytes',octet_length(payload.data::text),'entities',jsonb_array_length(payload.data->'entities')) FROM payload CROSS JOIN tick;
        SELECT pg_stat_force_next_flush();
        """)
        value=json.loads(next(line for line in data.splitlines() if line.startswith('{')))
        value['client_ms']=(time.perf_counter()-started)*1000
        return value
    single=query()
    print(json.dumps({'stores':stores,'payments':stores*200,'single':single}),flush=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        samples=list(pool.map(query,range(2,workers+2)))
    times=sorted(v['server_ms'] for v in samples)
    calls=sql("SELECT funcname,calls FROM pg_stat_user_functions WHERE funcname IN('get_pos_daily_sales_summary','pos_sales_export_source_revisions','pos_sales_export_source_revision') ORDER BY funcname;")
    result={'stores':stores,'payments':stores*200,'items':stores*200,'single':single,'concurrent_users':workers,
            'p50_server_ms':statistics.median(times),'p95_server_ms':times[max(0,int(len(times)*.95+.999)-1)],'function_calls':calls}
    results.append(result)
    if stores==500:
        plans=nested_plans()
        result['scan_rows_examined_including_repeated_scans']=plans['scan_rows_examined_including_repeated_scans']
        Path(output).with_suffix('.plans.json').write_text(json.dumps(plans,indent=2)+'\n')
    Path(output).parent.mkdir(parents=True,exist_ok=True)
    Path(output).write_text(json.dumps({'environment':'owned disposable Docker DB; synthetic data','results':results},indent=2)+'\n')
    print(json.dumps(result),flush=True)
