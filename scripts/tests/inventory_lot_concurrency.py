"""Real commits: idempotent hold release and competing releases of the last unit."""
import concurrent.futures
import json
from pathlib import Path
import subprocess
import sys
import time
import uuid

command = ['docker', 'exec', '-i', '--env', 'PGPASSWORD=fixture-only', sys.argv[1], 'psql', '-X', '-At', '-U', 'supabase_admin', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1']
def run(sql, check=True):
    result = subprocess.run(command, input=sql, text=True, capture_output=True, timeout=30)
    if check and result.returncode:
        raise AssertionError(result.stderr)
    return result

seed = Path('test/sql/inventory_lots_test.sql').read_text().split(' SELECT id INTO held_id')[0].replace('RAW-01', 'RACE-' + uuid.uuid4().hex[:8].upper())
seed = seed.replace('DO $$ DECLARE', 'CREATE TABLE public.fixture_inventory_lot_race(data jsonb);\nDO $$ DECLARE', 1)
seed += """
 INSERT INTO public.fixture_inventory_lot_race VALUES(jsonb_build_object('store',shop,'item',item,'actor',requester,'employee',employee.id,'po',po,'location',loc,'held',(SELECT id FROM inventory_lots WHERE ingredient_id=item AND state='held'),'inspection',payload->'p_lines'->0->'inspection'));
END $$;
COMMIT;
SELECT data FROM public.fixture_inventory_lot_race;
"""
r = run(seed)
meta = json.loads(next(line for line in r.stdout.splitlines() if line.startswith('{')))

def request(quantity, request_id=None):
    request_id = request_id or str(uuid.uuid4())
    receipt = str(uuid.uuid4())
    version = int(run(f"SELECT row_version FROM inventory_purchase_orders WHERE id='{meta['po']}';").stdout.strip())
    path = f"{meta['store']}/{receipt}/release.jpg"
    run(f"INSERT INTO storage.objects(bucket_id,name,owner_id,metadata) VALUES('inventory-receipt-statements','{path}','{meta['actor']}', '{{\"mimetype\":\"image/jpeg\",\"size\":100}}');")
    payload = {'employee_id': meta['employee'], 'reason': 'Concurrency fixture reinspection', 'evidence_reference': 'Isolated fixture document', 'receipt_id': receipt, 'location_id': meta['location'], 'expected_order_version': version, 'statement_storage_path': path, 'inspection': meta['inspection']}
    literal = json.dumps(payload).replace("'", "''")
    return f"BEGIN; SELECT set_config('request.jwt.claim.role','authenticated',true); SELECT set_config('request.jwt.claim.sub','{meta['actor']}',true); SELECT inventory_dispose_lot_v1('{request_id}','{meta['store']}','{meta['held']}','release',{quantity},'{literal}'::jsonb); COMMIT;"

started = time.monotonic()
same = request(2)
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    list(pool.map(run, [same] * 4))
assert run(f"SELECT current_stock FROM inventory_items WHERE id='{meta['item']}';").stdout.strip() == '8.000'
first, second = request(1), request(1)
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    replies = list(pool.map(lambda sql: run(sql, False), [first, second]))
assert sum(r.returncode == 0 for r in replies) == 1, [r.stderr for r in replies]
assert run(f"SELECT current_stock FROM inventory_items WHERE id='{meta['item']}';").stdout.strip() == '9.000'
assert run(f"SELECT quantity_base FROM inventory_lots WHERE id='{meta['held']}';").stdout.strip() == '0.000'
assert run('SELECT count(*) FROM inventory_lot_reconcile_queue;').stdout.strip() == '0'
print(f'INVENTORY_LOT_CONCURRENCY=PASS same_request_calls=4 postings=1 competing_last_unit=2 accepted=1 final_stock=9 elapsed_ms={round((time.monotonic()-started)*1000)}')
run('DROP TABLE public.fixture_inventory_lot_race;')
