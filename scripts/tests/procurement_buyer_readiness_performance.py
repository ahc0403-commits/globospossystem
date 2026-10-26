"""Measure the no-quote buyer backlog in the disposable procurement runner."""
import json
import pathlib
import subprocess
import sys

port, root = sys.argv[1:3]
source = (pathlib.Path(root) / 'supabase/migrations/20261023090000_procurement_buyer_approval_readiness.sql').read_text()
start = source.index(' WITH scopes AS MATERIALIZED')
end = source.index(' INTO result;', start)
query = source[start:end].replace('p_scopes', """(SELECT jsonb_agg(jsonb_build_object(
 'store_id',id,'brand_id',brand_id,'tax_entity_id',tax_entity_id,'actor',jsonb_build_object(
 'system','office','subject_id',test_uuid(270001),'store_id',id,'office_store_id',id,
 'role','staff','can_read',true,'can_office_approve',true)))
 FROM public.restaurants WHERE id IN(SELECT test_uuid(260000+n) FROM generate_series(1,STORE_COUNT)n))""")
query = query.replace('p_query', "'{}'::jsonb").replace('lim', '50')
command = ['psql', '-X', '-h', '127.0.0.1', '-p', port, '-d', 'postgres', '-v', 'ON_ERROR_STOP=1', '-Atq']

def run(sql):
    result = subprocess.run(command, input=sql, text=True, capture_output=True, check=True)
    return json.loads(result.stdout)

def walk(node):
    yield node
    for child in node.get('Plans', []):
        yield from walk(child)

results = []
for stores, count in [(2, 100), (20, 1000), (100, 10000)]:
    seed = f"""SET request.jwt.claim.role='service_role';SET app.procurement_write='true';
INSERT INTO public.restaurants(id,brand_id,tax_entity_id,name)
 SELECT test_uuid(260000+n),r.brand_id,r.tax_entity_id,'Buyer performance fixture '||n
 FROM generate_series(1,{stores})n CROSS JOIN public.restaurants r WHERE r.id=test_uuid(101);
INSERT INTO public.procurement_store_policies(restaurant_id,enabled,two_stage_required)
 SELECT test_uuid(260000+n),true,true FROM generate_series(1,{stores})n;
INSERT INTO public.inventory_purchase_requests(id,restaurant_id,source,status,requested_delivery_date,reason,
 created_actor,store_approved_actor,store_approved_at,submitted_at,approval_policy_version)
 SELECT test_uuid(280000+n),test_uuid(260001+(n%{stores})),'pos','office_review',current_date,'Missing quote backlog',
 jsonb_build_object('system','pos','subject_id',test_uuid(1)),
 jsonb_build_object('system','pos','subject_id',test_uuid(2)),now(),now()-interval '90 days'+n*interval '1 second',3
 FROM generate_series(1,{count})n;
ANALYZE public.inventory_purchase_requests;
"""
    sql = query.replace('STORE_COUNT', str(stores))
    plan = run('BEGIN;' + seed + 'EXPLAIN(ANALYZE,BUFFERS,FORMAT JSON)' + sql + ';ROLLBACK;')[0]
    payload = run('BEGIN;' + seed + sql + ';ROLLBACK;')
    scans = [node for node in walk(plan['Plan']) if node.get('Relation Name') == 'inventory_purchase_requests']
    assert scans and all(node['Actual Loops'] == 1 for node in scans)
    assert payload['approval_counts'] == {'pending': count, 'actionable': 0, 'blocked': count}
    assert len(payload['requests']) == 50 and payload['request_has_more']
    assert all(not row['approval_ready'] and 'PROCUREMENT_QUOTE_REQUIRED' in row['approval_blockers'] for row in payload['requests'])
    assert plan['Execution Time'] < 2000
    results.append({'stores': stores, 'requests': count, 'db_ms': plan['Execution Time'],
                    'returned_rows': len(payload['requests']), 'response_bytes': len(json.dumps(payload).encode()),
                    'request_scan_loops': [node['Actual Loops'] for node in scans]})
pathlib.Path('/tmp/procurement-buyer-readiness-performance.json').write_text(json.dumps(results, indent=2))
print('PASS: buyer no-quote readiness scaling ' + json.dumps(results))
