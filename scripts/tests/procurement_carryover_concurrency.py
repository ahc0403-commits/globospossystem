"""Exercise real concurrent RPC transactions and bounded receiving in a fixture DB."""
import concurrent.futures
import json
import pathlib
import subprocess
import sys
import time

port, root = sys.argv[1:3]
command = ['psql', '-X', '-h', '127.0.0.1', '-p', port, '-d', 'postgres', '-v', 'ON_ERROR_STOP=1', '-Atq']


def sql(source, check=True):
    result = subprocess.run(command, input=source, text=True, capture_output=True)
    if check and result.returncode:
        raise RuntimeError(result.stderr)
    return result


def uuid(number):
    return f'00000000-0000-4000-8000-{number:012d}'


def literal(value):
    return "'" + json.dumps(value, ensure_ascii=False).replace("'", "''") + "'::jsonb"


def actor(user=1):
    return f"SELECT set_config('request.jwt.claim.role','authenticated',false);SELECT set_config('request.jwt.claim.sub',test_uuid({user})::text,false);"


results = []
for count in (1, 20, 200):
    po_number, receipt_number = 140000 + count, 141000 + count
    source = f"""
SELECT set_config('app.procurement_write','true',false);
INSERT INTO public.inventory_purchase_orders(id,restaurant_id,supplier_id,purchase_order_no,status,workflow_version,procurement_status,commercial_terms)
VALUES(test_uuid({po_number}),test_uuid(101),test_uuid(201),'PO-CARRY-PERF-{count}','ordered',2,'confirmed','{{"approval_policy_version":3}}');
INSERT INTO public.inventory_purchase_order_lines(id,purchase_order_id,product_id,supplier_item_id,ordered_quantity_base,ordered_quantity_unit,order_unit,unit_price,supply_amount,tax_amount,recommendation_snapshot)
SELECT test_uuid({po_number * 10}+n),test_uuid({po_number}),test_uuid(301),test_uuid(401),10,10,'g',100,1000,0,
 jsonb_build_object('product_code','RAW-BENCH-'||n,'product_name','Fixture material '||n,'line_position',n,'tax_rate',0,'order_unit_quantity_base',1)
FROM generate_series(1,{count}) n;
INSERT INTO storage.objects(bucket_id,name,owner_id,metadata)
VALUES('inventory-receipt-statements',test_uuid(101)::text||'/'||test_uuid({receipt_number})::text||'/statement.pdf',test_uuid(1)::text,'{{"mimetype":"application/pdf","size":100}}');
"""
    sql(source)
    base_stock = float(sql('SELECT current_stock FROM public.inventory_items WHERE id=test_uuid(501);').stdout.strip())
    quantity = 7 if count == 1 else 10
    payload = {
        'p_purchase_order_id': uuid(po_number), 'p_receipt_id': uuid(receipt_number),
        'p_expected_order_version': 1, 'p_expected_receipt_version': 0,
        'p_idempotency_key': f'concurrent-receipt-{count}', 'p_inspector_name': 'Fixture inspector',
        'p_statement_storage_path': f'{uuid(101)}/{uuid(receipt_number)}/statement.pdf',
        'p_lines': [{'purchase_order_line_id': uuid(po_number * 10 + n), 'received_quantity_base': quantity,
                     'discrepancy_reason': 'Short fixture' if count == 1 else None,
                     'inspection': {'spec_ok': True, 'quality_ok': True, 'packaging_ok': True,
                                    'expiry_not_applicable': True, 'issue_type': 'shortage' if count == 1 else 'none', 'photo_paths': []}}
                    for n in range(1, count + 1)],
    }
    request = actor() + 'SELECT public.finalize_procurement_receipt(' + literal(payload) + ');'
    start = time.perf_counter()
    if count == 1:
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            answers = list(pool.map(lambda _: sql(request).stdout.splitlines()[-1], range(2)))
        assert answers[0] == answers[1], 'Concurrent exact receipt retries must return the same result'
        response = answers[0]
    else:
        response = sql(request).stdout.splitlines()[-1]
    elapsed = (time.perf_counter() - start) * 1000
    posted = json.loads(response)
    assert len(posted['report']['data']['lines']) == count
    final_stock = float(sql('SELECT current_stock FROM public.inventory_items WHERE id=test_uuid(501);').stdout.strip())
    assert final_stock == base_stock + quantity * count, 'Accepted stock posts exactly once'
    detail_request = actor() + f'SELECT public.get_inventory_workflow_detail(test_uuid({po_number}));'
    start_read = time.perf_counter()
    detail_raw = sql(detail_request).stdout.splitlines()[-1]
    detail_ms = (time.perf_counter() - start_read) * 1000
    detail = json.loads(detail_raw)
    assert len(detail['lines']) == count and len(detail['receipts']) == 1
    results.append({'lines': count, 'logical_write_rpc_calls': 1, 'write_rpc_calls': 2 if count == 1 else 1, 'read_rpc_calls': 1,
                    'receipt_retry_concurrency': 2 if count == 1 else 1,
                    'write_wall_ms': round(elapsed, 3), 'read_wall_ms': round(detail_ms, 3),
                    'write_response_bytes': len(response.encode()), 'read_response_bytes': len(detail_raw.encode()),
                    'stock_posted_once': True, 'measurement': 'isolated DB RPC plus psql process overhead; network/app memory not measured'})

# Two different PRs compete for the same actual short delivery.
payload = {'reason': 'Concurrent shortage reservation', 'requested_delivery_date': '2026-10-15',
           'lines': [{'product_id': uuid(301), 'quantity': 3, 'unit': 'g', 'preferred_supplier_id': uuid(201),
                      'shortage_sources': [{'original_order_line_id': uuid(140001 * 10 + 1), 'quantity_base': 3}]}]}


def reserve(index):
    return sql(actor(index + 1) + "SELECT public.procurement_command(test_uuid(101),'create_request',NULL,0,'reservation-race-"
               + str(index) + "'," + literal(payload) + ');', check=False)


with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    attempts = list(pool.map(reserve, range(2)))
assert sum(result.returncode == 0 for result in attempts) == 1, [r.stderr for r in attempts]
assert any('PROCUREMENT_SHORTAGE_CHANGED' in result.stderr for result in attempts)
assert sql("SELECT sum(quantity_base) FROM public.procurement_shortage_allocations WHERE original_order_line_id=test_uuid(1400011) AND status='reserved';").stdout.strip() == '3.000'
out = pathlib.Path(root) / 'outputs/procurement-20261013'
out.mkdir(parents=True, exist_ok=True)
(out / 'performance.json').write_text(json.dumps({'paths': results, 'reservation_race': 'one succeeds, one rejects stale shortage'}, indent=2))
print('PASS: concurrent receipt replay, competing shortage reservations, and measured 1/20/200-line RPCs: ' + json.dumps(results))
