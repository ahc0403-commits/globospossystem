"""Real concurrent manager RPCs and bounded adjustment batches in the fixture DB."""
import concurrent.futures
import json
import subprocess
import sys
import threading
import time

port = sys.argv[1]
command = ['psql', '-X', '-h', '127.0.0.1', '-p', port, '-d', 'postgres',
           '-v', 'ON_ERROR_STOP=1', '-Atq']


def sql(source, check=True):
    result = subprocess.run(command, input=source, text=True, capture_output=True)
    if check and result.returncode:
        raise RuntimeError(result.stderr)
    return result


def value(payload):
    return "'" + json.dumps(payload).replace("'", "''") + "'::jsonb"


def actor(number):
    return ("SELECT set_config('request.jwt.claim.role','authenticated',false);"
            f"SELECT set_config('request.jwt.claim.sub',test_uuid({number})::text,false);")


def uuid(number):
    return f'00000000-0000-4000-8000-{number:012d}'


sql("""UPDATE public.procurement_store_policies SET enabled=true,two_stage_required=true,
new_requests_enabled=true WHERE restaurant_id=test_uuid(101);
INSERT INTO public.inventory_products(id,restaurant_id,name,base_unit,stock_unit,base_unit_factor,is_active,is_orderable)
SELECT test_uuid(28500+n),test_uuid(101),'Adjustment fixture '||n,'g','kg',1000,true,true
FROM generate_series(1,200) n;""")


def request(key):
    payload = {'reason': 'Adjustment concurrency fixture', 'requested_delivery_date': '2099-01-01',
               'lines': [{'product_id': uuid(301), 'quantity': 10, 'unit': 'g'}]}
    text = sql(actor(1) + f"SELECT public.procurement_command(test_uuid(101),'create_request',NULL,0,'{key}',{value(payload)});").stdout
    rid = json.loads(text.splitlines()[-1])['id']
    sql(actor(1) + f"SELECT public.procurement_command(test_uuid(101),'submit_request','{rid}',1,'{key}-submit');")
    lid = sql(f"SELECT id FROM public.inventory_purchase_request_lines WHERE request_id='{rid}' AND active;").stdout.strip()
    return rid, lid


def adjustment(rid, lid, key, products, barrier=None):
    payload = {'reason': 'Manager adjustment', 'lines': [{'request_line_id': lid, 'quantity': 12}],
               'new_lines': [{'product_id': uuid(n), 'quantity': 1, 'unit': 'g'} for n in products]}
    if barrier:
        barrier.wait(timeout=10)
    return sql(actor(2) + f"SELECT public.procurement_command(test_uuid(101),'adjust_request','{rid}',2,'{key}',{value(payload)});", check=False)


measurements = []
for count in (1, 20, 199):
    rid, lid = request(f'adjust-size-{count}')
    start = time.monotonic()
    result = adjustment(rid, lid, f'adjust-size-{count}-apply', range(28501, 28501 + count))
    assert result.returncode == 0, result.stderr
    response = result.stdout.splitlines()[-1]
    assert len(json.loads(response)['lines']) == count + 1
    measurements.append({'added': count, 'returned_lines': count + 1,
                         'response_bytes': len(response.encode()),
                         'client_ms': round((time.monotonic() - start) * 1000, 3)})

for same_key in (False, True):
    rid, lid = request(f'adjust-race-{same_key}')
    barrier = threading.Barrier(2)
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(adjustment, rid, lid,
                               'adjust-same-key' if same_key else f'adjust-race-{n}',
                               [28501] if same_key else [28501 + n], barrier)
                   for n in range(2)]
        results = [f.result(timeout=30) for f in futures]
    if same_key:
        assert all(r.returncode == 0 for r in results), [r.stderr for r in results]
        assert json.loads(results[0].stdout.splitlines()[-1]) == json.loads(results[1].stdout.splitlines()[-1])
    else:
        assert sum(r.returncode == 0 for r in results) == 1
        assert any('PROCUREMENT_STALE_VERSION' in r.stderr for r in results)
    assert sql(f"SELECT count(*) FROM public.inventory_purchase_request_lines WHERE request_id='{rid}' AND active;").stdout.strip() == '2'
    assert sql(f"SELECT count(*) FROM public.procurement_events WHERE record_id='{rid}' AND action='adjust_request';").stdout.strip() == '1'

print('PASS: atomic manager adjustment, concurrent conflict and identical retry; bounded batches ' + json.dumps(measurements))
