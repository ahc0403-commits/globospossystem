"""Real transactions: competing owner confirmations cannot claim a receipt twice."""
import concurrent.futures
import json
import subprocess
import sys
import time
import uuid
command = ['docker','exec','-i','--env','PGPASSWORD=fixture-only',sys.argv[1],'psql','-X','-At','-U','supabase_admin','-d','postgres','-v','ON_ERROR_STOP=1']
actor = "SELECT set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000099',true);"
entity = '91000000-0000-4000-8000-000000000004'
def run(sql):
    return subprocess.run(command, input=sql, text=True, capture_output=True, timeout=45)
ids = [str(uuid.uuid4()), str(uuid.uuid4())]
for batch_id in ids:
    sql = f"""BEGIN; {actor}
    SELECT public.admin_prepare_sales_batch_v1('{batch_id}',(now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date,'{entity}',
      public.pos_sales_export_source_revision((now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date,'{entity}'),
      coalesce((SELECT revision FROM public.sales_invoice_mapping_revisions WHERE tax_entity_id='{entity}'),0));
    SELECT public.admin_update_sales_batch_v1('{batch_id}','generated','{{"sha256":"{'a'*64}","size":1024}}'); COMMIT;"""
    r=run(sql)
    assert r.returncode == 0, r.stderr
started = time.monotonic()
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    results=list(pool.map(run,[f"BEGIN; {actor} SELECT public.admin_update_sales_batch_v1('{i}','confirm','{{\"sha256\":\"{'a'*64}\"}}'); SELECT pg_sleep(0.15); COMMIT;" for i in ids]))
assert sum(r.returncode == 0 for r in results) == 1, [(r.returncode,r.stderr) for r in results]
assert any('SALES_BATCH_RECEIPT_ALREADY_CONFIRMED' in r.stderr for r in results)
for i in ids:
    r=run(f"BEGIN; {actor} SELECT public.admin_update_sales_batch_v1('{i}','void','{{\"reason\":\"Isolated concurrency fixture complete\"}}'); COMMIT;")
    assert r.returncode == 0, r.stderr
print(f'SALES_REPORTING_CONCURRENCY=PASS confirmations=2 accepted=1 duplicate_claims=0 elapsed_ms={round((time.monotonic()-started)*1000)}')
