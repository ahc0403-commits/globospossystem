"""Race real quote/proof writers against amendments in the disposable database."""
import concurrent.futures
import json
import subprocess
import sys
import threading

container = sys.argv[1]
assert container == 'order-amend-test' or container.startswith('globos-direct-fallback-test-')
claims = "SET request.jwt.claim.sub='00000000-0000-4000-8000-000000000001';SET request.jwt.claims='" + json.dumps({'sub': '00000000-0000-4000-8000-000000000001', 'role': 'authenticated'}) + "';"

def sql(statement):
    return subprocess.run(['docker', 'exec', container, 'psql', '-XqAt', '-U', 'postgres', '-d', 'codex_direct_photo', '-v', 'ON_ERROR_STOP=1', '-c', claims + statement], text=True, capture_output=True)

def checked(statement):
    r = sql(statement)
    assert r.returncode == 0, r.stderr
    return r.stdout.strip()

checked("""CREATE OR REPLACE FUNCTION guide_test.amendment_fixture(quoted boolean) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE r uuid; q jsonb; result jsonb;
BEGIN
 r:=guide_test.request();
 IF quoted THEN q:=public.direct_order_staff_quote_with_payment_mode('d1000000-0000-4000-8000-000000000002',r,0,NULL,'customer_direct'); END IF;
 SELECT jsonb_build_object('rid',r,'sid',s.id,'secret',s.secret_hash,'token',public.direct_order_edit_token(r),'quote',q->>'id','line',i.id)
 INTO result FROM direct_order_requests req JOIN direct_order_sessions s ON s.id=req.session_id JOIN direct_order_request_items i ON i.request_id=req.id WHERE req.id=r;
 RETURN result;
END $$""")

def race(statements):
    barrier = threading.Barrier(len(statements))
    def run(statement):
        barrier.wait(timeout=20)
        return sql(statement)
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(statements)) as pool:
        return list(pool.map(run, statements))

def edit(f, operation='gen_random_uuid()'):
    payload = json.dumps({'existing': [{'id': f['line'], 'quantity': 2}], 'additions': []})
    return f"SELECT public.direct_order_public_amend('{f['sid']}','{f['secret']}','{f['rid']}',{operation},'{f['token']}','{payload}'::jsonb)"

f = json.loads(checked('SELECT guide_test.amendment_fixture(false)'))
op = checked('SELECT gen_random_uuid()')
r = race([edit(f, f"'{op}'"), edit(f, f"'{op}'")])
assert all(x.returncode == 0 for x in r), [x.stderr for x in r]
assert checked(f"SELECT count(*) FROM direct_order_amendments WHERE request_id='{f['rid']}'") == '1'
print('AMENDMENT_DUPLICATE_RACE=PASS logical_edits=1')

f = json.loads(checked('SELECT guide_test.amendment_fixture(false)'))
quote = f"SELECT public.direct_order_staff_quote_current('d1000000-0000-4000-8000-000000000002','{f['rid']}',0,NULL,'customer_direct','{f['token']}')"
r = race([edit(f), quote])
assert sum(x.returncode == 0 for x in r) == 1, [x.stderr for x in r]
assert any('DIRECT_ORDER_AMENDMENT_STALE' in x.stderr for x in r)
print('AMENDMENT_QUOTE_RACE=PASS winners=1 stale=1')

f = json.loads(checked('SELECT guide_test.amendment_fixture(true)'))
path = 'd1000000-0000-4000-8000-000000000002/' + f['rid'] + '/' + checked('SELECT gen_random_uuid()') + '.png'
proof = f"SELECT public.direct_order_public_proof_v3('{f['sid']}','{f['secret']}','{f['rid']}','{f['quote']}',NULL,NULL,'{path}')"
r = race([edit(f), proof])
assert sum(x.returncode == 0 for x in r) == 1, [x.stderr for x in r]
assert any('DIRECT_ORDER_AMENDMENT_NOT_ALLOWED' in x.stderr or 'DIRECT_ORDER_PROOF_NOT_ALLOWED' in x.stderr for x in r), [x.stderr for x in r]
print('AMENDMENT_PROOF_RACE=PASS winners=1 old_quote_cannot_be_paid=PASS')
