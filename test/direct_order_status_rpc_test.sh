#!/usr/bin/env bash
set -euo pipefail
STATUS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# == 0 ]]; then
  exec bash "$STATUS_ROOT/test/direct_order_support_sql_test.sh"
fi
STATUS_DB="$1"
[[ "$STATUS_DB" == globos-direct-fallback-test-* ]] || { printf 'DISPOSABLE_DATABASE_REQUIRED\n'; exit 1; }
STATUS_NETWORK="globos-status-rpc-$$"
STATUS_REST="${STATUS_NETWORK}-rest"
cleanup() {
  docker rm -f "$STATUS_REST" >/dev/null 2>&1 || true
  docker network disconnect "$STATUS_NETWORK" "$STATUS_DB" >/dev/null 2>&1 || true
  docker network rm "$STATUS_NETWORK" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker network create "$STATUS_NETWORK" >/dev/null
docker network connect "$STATUS_NETWORK" "$STATUS_DB"
docker run --detach --rm --name "$STATUS_REST" --network "$STATUS_NETWORK" \
  --publish 127.0.0.1::3000 \
  --env "PGRST_DB_URI=postgres://postgres@${STATUS_DB}:5432/codex_direct_photo" \
  --env PGRST_DB_ANON_ROLE=service_role --env PGRST_DB_SCHEMAS=public \
  public.ecr.aws/supabase/postgrest:v14.5 >/dev/null
STATUS_ADDRESS="$(docker port "$STATUS_REST" 3000/tcp)"
for attempt in $(seq 1 60); do
  if curl --fail --silent "http://${STATUS_ADDRESS}/" >/dev/null; then break; fi
  if [[ "$attempt" == 60 ]]; then docker logs --tail 30 "$STATUS_REST"; exit 1; fi
  sleep 1
done
python3 - "$STATUS_ROOT" "$STATUS_DB" "http://${STATUS_ADDRESS}" <<'PY'
import json
from pathlib import Path
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid

root, db, url = Path(sys.argv[1]), sys.argv[2], sys.argv[3]

def sql(query):
    return subprocess.check_output([
        'docker', 'exec', db, 'psql', '-X', '-At', '-U', 'postgres',
        '-d', 'codex_direct_photo', '-v', 'ON_ERROR_STOP=1', '-c', query,
    ], text=True).strip()

def apply(path):
    subprocess.run([
        'docker', 'exec', '-i', db, 'psql', '-X', '-U', 'postgres',
        '-d', 'codex_direct_photo', '-v', 'ON_ERROR_STOP=1',
    ], input=(root / path).read_text(), text=True, check=True,
       stdout=subprocess.DEVNULL)

def rpc(name, body):
    request = urllib.request.Request(
        f'{url}/rpc/{name}', data=json.dumps(body).encode(),
        headers={'Content-Type': 'application/json'}, method='POST',
    )
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        return error.code, json.load(error)

def counts():
    return sql("SELECT jsonb_build_array("
               "(SELECT count(*) FROM orders),"
               "(SELECT count(*) FROM payments),"
               "(SELECT count(*) FROM direct_order_financials),"
               "(SELECT count(*) FROM inventory_transactions))")

import os
if os.environ.get('DIRECT_ORDER_STATUS_V7_TEST') == '1' or os.environ.get('DIRECT_ORDER_STATUS_V9_TEST') == '1':
    data=json.loads(sql("SELECT jsonb_build_object('p_session_id',r.session_id,'p_secret_hash',s.secret_hash,'p_request_id',r.id) FROM direct_order_requests r JOIN direct_order_sessions s ON s.id=r.session_id WHERE public.direct_order_access_is_open(r.id) LIMIT 1"))
    before=counts()
    versions = (8,9) if os.environ.get('DIRECT_ORDER_STATUS_V9_TEST') == '1' else (7,)
    for version in versions:
        sql(f"UPDATE direct_order_sessions SET last_seen_at=now()-interval '2 hours' WHERE id='{data['p_session_id']}'")
        code,value=rpc(f'direct_order_public_status_v{version}',data)
        assert code==200 and value['request_id']==data['p_request_id'],(code,value)
        assert sql(f"SELECT last_seen_at>now()-interval '1 minute' FROM direct_order_sessions WHERE id='{data['p_session_id']}'")=='t'
        assert counts()==before
        if version==9: assert isinstance(value['requirements'],list)
        print(f'DIRECT_ORDER_STATUS_V{version}_POSTGREST=PASS http=200 session_touch=PASS business_writes=0')
    raise SystemExit(0)
target = "'public.direct_order_public_status_v5(uuid,text,uuid)'::regprocedure"
original = sql(f'SELECT pg_get_functiondef({target})')
assert sql(f'SELECT provolatile FROM pg_proc WHERE oid={target}') == 's'
secret = 'a' * 64  # Disposable fixture hash only.
code, session = rpc('direct_order_public_create_session', {
    'p_slug': 'photo-test', 'p_secret_hash': secret, 'p_locale': 'ko',
})
assert code == 200, (code, session)
sid = session['session_id']
submit_body = {
    'p_session_id': sid, 'p_secret_hash': secret,
    'p_client_request_id': str(uuid.uuid4()),
    'p_payload': {
        'locale': 'ko', 'fulfillment_type': 'delivery', 'diner_count': 2,
        'items': [{'menu_item_id': 'd1000000-0000-4000-8000-000000000003', 'quantity': 1}],
        'address': {'customer_name': 'RPC fixture', 'customer_phone': '0900000000',
                    'formatted_address': '123 Fixture Street', 'detail_address': 'Floor 1',
                    'address_source': 'manual', 'location_verified': False},
    },
}
code, submitted = rpc('direct_order_public_submit_v3', submit_body)
assert code == 200 and submitted['state'] == 'awaiting_quote', (code, submitted)
rid = submitted['request_id']
status_body = {'p_session_id': sid, 'p_secret_hash': secret, 'p_request_id': rid}
business_before = counts()
code, failed = rpc('direct_order_public_status_v5', status_body)
assert code == 405 and failed['code'] == '25006', (code, failed)
assert failed['message'] == 'cannot execute UPDATE in a read-only transaction'
assert sql(f"SELECT count(*) FROM direct_order_requests WHERE id='{rid}'") == '1'
print('DIRECT_ORDER_STATUS_RPC_BEFORE=PASS submitted=1 status_http=405 sql_state=25006')

apply('scripts/preflight_direct_order_status_session_activity.sql')
apply('supabase/migrations/20261009010000_direct_order_status_session_activity.sql')
apply('scripts/verify_direct_order_status_session_activity.sql')

def restored_status():
    # NOTIFY reloads PostgREST's cached volatility asynchronously.
    for _ in range(30):
        code, value = rpc('direct_order_public_status_v5', status_body)
        if code == 200:
            return value
        assert code == 405 and value['code'] == '25006', (code, value)
        time.sleep(0.1)
    raise AssertionError('PostgREST schema cache did not reload')

value = restored_status()
assert value['request_id'] == rid and value['state'] == 'awaiting_quote'
assert 'customer' in value and 'support' in value and 'delivery' in value
pickup = json.loads(sql("SELECT photo_test.create_request(false,'customer_direct','pickup')"))
pickup_rid = pickup['request_id']
pickup_session = json.loads(sql(
    f"SELECT jsonb_build_object('p_session_id',s.id,'p_secret_hash',s.secret_hash,"
    f"'p_request_id',r.id) FROM direct_order_requests r JOIN direct_order_sessions s "
    f"ON s.id=r.session_id WHERE r.id='{pickup_rid}'"))
code, pickup_status = rpc('direct_order_public_status_v5', pickup_session)
assert code == 200 and pickup_status['fulfillment_type'] == 'pickup'
for version in (3, 4):
    code, legacy = rpc(f'direct_order_public_status_v{version}', status_body)
    assert code == 200 and legacy['request_id'] == rid and 'support' not in legacy
code, replay = rpc('direct_order_public_submit_v3', submit_body)
assert code == 200 and replay['request_id'] == rid and replay['idempotent'] is True
assert sql(f"SELECT count(*) FROM direct_order_requests WHERE session_id='{sid}'") == '1'
assert sql(f"SELECT last_seen_at > created_at FROM direct_order_sessions WHERE id='{sid}'") == 't'
for overrides in ({'p_secret_hash': 'b' * 64}, {'p_request_id': str(uuid.uuid4())}):
    code, denied = rpc('direct_order_public_status_v5', dict(status_body, **overrides))
    assert code >= 400 and denied['code'] == 'P0001', (code, denied)
code, denied = rpc('direct_order_public_status_v5', dict(
    status_body, p_session_id=pickup_session['p_session_id'],
    p_secret_hash=pickup_session['p_secret_hash']))
assert code >= 400 and denied['code'] == 'P0001', (code, denied)
assert counts() == business_before, 'Status/replay changed payment or inventory data'
fixed = sql(f'SELECT pg_get_functiondef({target})')
assert original.replace(' STABLE SECURITY DEFINER', ' SECURITY DEFINER') == fixed, 'RPC definition changed beyond volatility'
print('DIRECT_ORDER_STATUS_RPC_AFTER=PASS delivery=200 pickup=200 session_touch=PASS ownership=PASS replay=PASS legacy=PASS business_writes=0')

apply('scripts/rollback_direct_order_status_session_activity.sql')
assert sql(f'SELECT pg_get_functiondef({target})') == original
apply('scripts/preflight_direct_order_status_session_activity.sql')
apply('supabase/migrations/20261009010000_direct_order_status_session_activity.sql')
apply('scripts/verify_direct_order_status_session_activity.sql')
restored_status()
assert counts() == business_before
print('DIRECT_ORDER_STATUS_RPC_ROLLBACK_AND_REAPPLY=PASS')
PY
