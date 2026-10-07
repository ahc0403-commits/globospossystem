"""Measure the PR parent page and filtered counts inside an isolated fixture DB."""
import json
import pathlib
import re
import subprocess
import sys

port, root = sys.argv[1:3]
cmd = ['psql', '-X', '-h', '127.0.0.1', '-p', port, '-d', 'postgres',
       '-v', 'ON_ERROR_STOP=1', '-Atq']


def sql(value):
    return subprocess.run(cmd, input=value, text=True, capture_output=True,
                          check=True).stdout.strip()


def walk(plan):
    yield plan
    for child in plan.get('Plans', []):
        yield from walk(child)


source = (pathlib.Path(root) / 'supabase/migrations/20261007095000_procurement_pr_account.sql').read_text()
start = source.index('WITH filtered AS NOT MATERIALIZED')
end = source.index(';', source.index('INTO requests,request_counts', start))
query = source[start:end].replace('INTO requests,request_counts', '')
params = {'p_store_id': 'test_uuid(101)', 'lim': '20', 'created_sort': 'true',
          'p_query': "'{\"search\":\"PR benchmark\",\"purchase_category\":\"beverage\",\"request_group\":\"pending\"}'::jsonb",
          'actor': "'{}'::jsonb", 'policy': "'{\"enabled\":false}'::jsonb"}
for name, value in params.items():
    query = re.sub(r'\b' + name + r'\b', lambda _: value, query)
results = []
out = pathlib.Path('/tmp/procurement-pr-explain-20261007')
out.mkdir(exist_ok=True)
for count in [100, 1000, 10000]:
    seed = f"""
INSERT INTO public.inventory_purchase_requests(id,restaurant_id,source,requested_delivery_date,reason,created_actor,purchase_category,created_at)
SELECT test_uuid(990000+n),test_uuid(101),'pos',current_date,'PR benchmark','{{}}','beverage',now()-n*interval '1 minute' FROM generate_series(1,{count}) n;
INSERT INTO public.inventory_purchase_request_lines(request_id,product_id,requested_quantity,requested_unit,quantity_base,conversion_snapshot)
SELECT test_uuid(990000+n),test_uuid(301),1,'g',1,1 FROM generate_series(1,{count}) n;
ANALYZE public.inventory_purchase_requests;
ANALYZE public.inventory_purchase_request_lines;
"""
    plan = json.loads(sql('BEGIN;' + seed + f'EXPLAIN (ANALYZE,BUFFERS,FORMAT JSON) {query};ROLLBACK;'))[0]
    assert not any(p.get('Subplan Name', '').startswith('SubPlan') for p in walk(plan['Plan'])), 'No correlated per-request aggregate'
    assert plan['Execution Time'] < 1500, 'PR page regression in isolated DB'
    (out / f'pr-{count}.json').write_text(json.dumps(plan, indent=2))
    values = sql('BEGIN;' + seed + query + ';ROLLBACK;').split('|')
    requests, counts = map(json.loads, values)
    assert len(requests) == 21 and counts['pending'] == count
    assert all(r['line_count'] == 1 for r in requests)
    results.append({'history_requests': count, 'parent_limit_plus_cursor': len(requests),
                    'filtered_pending_count': counts['pending'], 'db_plan_ms': plan['Execution Time'],
                    'shared_hit_blocks': plan['Plan'].get('Shared Hit Blocks', 0),
                    'api_read_calls': 1, 'measurement': 'isolated SQL; transport excluded'})
(out / 'summary.json').write_text(json.dumps(results, indent=2))
print('PASS: created PR pages and grouped counts at 100/1000/10000 requests: ' + json.dumps(results))
