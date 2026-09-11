"""Exercise row-lock races using two real authenticated PostgreSQL sessions."""
import json
import subprocess
import sys

PSQL = ['psql', '-X', '-qAt', '-h', '127.0.0.1', '-p', sys.argv[1],
        '-d', 'postgres', '-v', 'ON_ERROR_STOP=1']


def query(sql):
    return subprocess.check_output(PSQL + ['-c', sql], text=True).strip()


def literal(value):
    return "'" + str(value).replace("'", "''") + "'"


def uuid(number):
    return f'00000000-0000-4000-8000-{number:012d}'


def as_actor(actor, sql):
    return (f"SET ROLE authenticated; SET request.jwt.claim.sub={literal(uuid(actor))}; "
            + sql)


def race(actor, sql, second_error=None):
    # The first session holds its business locks after the function returns.
    first = subprocess.Popen(PSQL, stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    first.stdin.write('BEGIN;\n' + as_actor(actor, sql).replace('; ', ';\n')
                      + ';\nSELECT pg_sleep(1);\nCOMMIT;\n')
    first.stdin.close()
    first.stdin = None
    first_result = first.stdout.readline().strip()
    if not first_result:
        _, error = first.communicate(timeout=15)
        raise AssertionError(error)
    second = subprocess.Popen(PSQL + ['-c', as_actor(actor, sql)],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    _, first_error = first.communicate(timeout=15)
    second_result, error = second.communicate(timeout=15)
    assert first.returncode == 0, first_error
    if second_error:
        assert second.returncode != 0 and second_error in error, error
    else:
        assert second.returncode == 0, error
        assert first_result == second_result.strip(), (first_result, second_result)


order = json.loads(query(as_actor(2, """
SELECT to_jsonb(public.store_decide_inventory_purchase_order(
  (public.submit_inventory_purchase_order(
    (public.create_manual_inventory_purchase_order(test_uuid(101),test_uuid(201),
      jsonb_build_array(jsonb_build_object('supplier_item_id',test_uuid(401),
        'ordered_quantity_unit',1)),current_date,NULL)).id,1)).id,2,true,NULL))
""")))
order_id = literal(order['id'])
race(3, f"SELECT (public.brand_decide_inventory_purchase_order({order_id},3,true,NULL)).status",
     'INVENTORY_PURCHASE_INVALID_TRANSITION')
assert query(f"SELECT count(*) FROM inventory_purchase_documents WHERE purchase_order_id={order_id}") == '1'
detail = json.loads(query(as_actor(1, f'SELECT public.get_inventory_workflow_detail({order_id})')))
payload = json.dumps([{'purchase_order_line_id': detail['lines'][0]['id'],
                       'received_quantity_base': 10, 'actual_unit_price': 100}])
receipt = literal(uuid(704))
path = literal(f'{uuid(101)}/{uuid(704)}/race.pdf')
query(f"INSERT INTO storage.objects(bucket_id,name,metadata,owner_id) VALUES "
      f"('inventory-receipt-statements',{path},"
      f"'{{\"mimetype\":\"application/pdf\",\"size\":100}}',{literal(uuid(1))})")
capture = (f"SELECT public.submit_inventory_receipt_batch({order_id},{receipt},4,0,"
           f"'concurrent-capture',{literal(payload)}::jsonb,'Inspector',{path})")
race(1, capture)
assert query(f'SELECT count(*) FROM inventory_receipt_lines WHERE receipt_id={receipt}') == '1'
assert query(f'SELECT count(*) FROM inventory_receipt_submission_attempts WHERE receipt_id={receipt}') == '1'
race(4, f"SELECT (public.verify_inventory_receipt({receipt},2,'concurrent-verify')).status")
assert query(f'SELECT count(*) FROM inventory_transactions WHERE reference_id={receipt}') == '1'
assert query(f'SELECT current_stock FROM inventory_items WHERE id={literal(uuid(501))}') == '210.000'
print('PASS: concurrent brand approval, batch retry and accounting verify; one document/submission/stock posting')
