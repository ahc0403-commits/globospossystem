"""Real row-lock races and bounded authorization measurements in a local DB."""
import concurrent.futures
import json
import statistics
import subprocess
import sys
import time

container = sys.argv[1]
assert container.startswith('globos-direct-fallback-test-')


def sql(statement):
    claims = json.dumps({'sub': '00000000-0000-4000-8000-000000000001', 'role': 'authenticated'})
    return subprocess.run(['docker', 'exec', container, 'psql', '-X', '-qAt', '-U', 'postgres',
                           '-d', 'codex_direct_photo', '-v', 'ON_ERROR_STOP=1', '-c',
                           "SET request.jwt.claim.sub='00000000-0000-4000-8000-000000000001';" +
                           f"SET request.jwt.claims='{claims}';" + statement],
                          capture_output=True, text=True)


def checked(statement):
    result = sql(statement)
    if result.returncode:
        raise RuntimeError(result.stderr)
    return result.stdout.strip()


def call(f, previous, path):
    return f"SELECT proof_test.send('{json.dumps(f)}'::jsonb,'{previous}','{path}')"


for kind in ['replace', 'approve_first', 'replace_first']:
    scope = json.loads(checked(f"SELECT scope FROM proof_test.races WHERE kind='{kind}'"))
    old = scope['proof_id']
    path_a = checked(f"SELECT proof_test.path('{json.dumps(scope)}'::jsonb)")
    path_b = checked(f"SELECT proof_test.path('{json.dumps(scope)}'::jsonb)")
    replacement = call(scope, old, path_a)
    approval = ("SELECT public.direct_order_record_receipt("
                f"'{scope['store_id']}','{scope['request_id']}','{scope['quote_id']}',"
                f"'{old}',108000,'race-{scope['request_id']}')")
    first, second = ((replacement, call(scope, old, path_b)) if kind == 'replace'
                     else (approval, replacement) if kind == 'approve_first'
                     else (replacement, approval))
    app = f'proof-race-{kind}'
    first = (f"SET application_name='{app}'; BEGIN; {first}; SELECT pg_sleep(0.5); COMMIT;")
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        a = pool.submit(sql, first)
        # Wait for the first connection to hold its lock before starting the rival.
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if checked(f"SELECT count(*) FROM pg_stat_activity WHERE application_name='{app}' AND wait_event='PgSleep'") == '1':
                break
            time.sleep(0.025)
        else:
            raise AssertionError('First race connection did not acquire the lock')
        b = pool.submit(sql, second)
        result_a, result_b = a.result(), b.result()
    assert result_a.returncode == 0, result_a.stderr
    expected = 'DIRECT_ORDER_PROOF_NOT_ALLOWED' if kind == 'approve_first' else 'DIRECT_ORDER_PAYMENT_REVIEW_CHANGED'
    assert result_b.returncode != 0 and expected in result_b.stderr, result_b.stderr
    if kind != 'approve_first':
        checked(f"""SELECT public.direct_order_record_receipt('{scope['store_id']}','{scope['request_id']}',
          '{scope['quote_id']}',(SELECT id FROM public.direct_order_messages
           WHERE attachment_storage_path='{path_a}'),108000,'race-{scope['request_id']}')""")
    assert checked(f"SELECT count(*) FROM public.direct_order_payment_receipts WHERE request_id='{scope['request_id']}'") == '1'
    assert checked(f"SELECT count(*) FROM public.direct_order_financials WHERE request_id='{scope['request_id']}'") == '1'
    print(f'PROOF_RACE={kind} PASS receipts=1 financials=1 stale_action_rejected=true', flush=True)

# Each independent customer makes one authorization RPC. Chat growth must not
# introduce a status RPC or per-message function calls on the authorization path.
for clients in [1, 10, 50]:
    for messages in [1, 20, 100]:
        scopes = json.loads(checked(f"SELECT jsonb_agg(proof_test.scope()) FROM generate_series(1,{clients})"))
        ids = ','.join("'" + f['request_id'] + "'::uuid" for f in scopes)
        checked(f"""INSERT INTO public.direct_order_messages(request_id,restaurant_id,sender_type,message_type,body)
          SELECT r.id,r.restaurant_id,'customer','text','fixture chat'
          FROM public.direct_order_requests r CROSS JOIN generate_series(1,{messages})
          WHERE r.id IN ({ids})""")
        def measure(f):
            started = time.monotonic()
            value = json.loads(checked(f"SELECT proof_test.send('{json.dumps(f)}'::jsonb,'{f['proof_id']}')"))
            return (time.monotonic()-started)*1000, len(json.dumps(value).encode())
        with concurrent.futures.ThreadPoolExecutor(max_workers=clients) as pool:
            measurements = list(pool.map(measure, scopes))
        times = sorted(t for t, _ in measurements)
        print(f'PROOF_AUTH clients={clients} chat_per_order={messages} rpc_per_customer=1 '
              f'p50_ms={statistics.median(times):.2f} p95_ms={times[min(len(times)-1,int(len(times)*.95))]:.2f} '
              f'max_response_bytes={max(n for _,n in measurements)} docker_cli_included=true', flush=True)
        def measure_update(f):
            started = time.monotonic()
            value = json.loads(checked(f"SELECT public.direct_order_public_updates('{f['session_id']}','{f['secret']}','{f['request_id']}')"))
            return (time.monotonic()-started)*1000, len(json.dumps(value).encode())
        with concurrent.futures.ThreadPoolExecutor(max_workers=clients) as pool:
            updates = list(pool.map(measure_update, scopes))
        update_times = sorted(t for t, _ in updates)
        print(f'CHAT_CHECK clients={clients} chat_per_order={messages} rpc_per_customer=1 '
              f'p50_ms={statistics.median(update_times):.2f} p95_ms={update_times[min(len(update_times)-1,int(len(update_times)*.95))]:.2f} '
              f'max_response_bytes={max(n for _,n in updates)} docker_cli_included=true', flush=True)

f = scopes[0]
plan = checked(f"""EXPLAIN (ANALYZE,BUFFERS,FORMAT JSON) SELECT id FROM public.direct_order_messages
 WHERE request_id='{f['request_id']}' AND restaurant_id='{f['store_id']}'
 AND sender_type='customer' AND message_type='payment_proof' AND attachment_storage_path IS NOT NULL
 AND metadata->>'quote_id'='{f['quote_id']}' AND metadata->>'charge_id' IS NULL
 ORDER BY created_at DESC,id DESC LIMIT 1""")
parsed = json.loads(plan)[0]
print('PROOF_LATEST_EXPLAIN=' + json.dumps(parsed), flush=True)
plan = checked(f"""EXPLAIN (ANALYZE,BUFFERS,FORMAT JSON) SELECT chat_revision,updated_at,pii_purged_at
 FROM public.direct_order_requests WHERE id='{f['request_id']}' AND session_id='{f['session_id']}'
 AND restaurant_id='{f['store_id']}'""")
print('CHAT_REVISION_EXPLAIN=' + json.dumps(json.loads(plan)[0]), flush=True)
proof_path = checked(f"SELECT attachment_storage_path FROM public.direct_order_messages WHERE id='{f['proof_id']}'")
plan = checked(f"""EXPLAIN (ANALYZE,BUFFERS,FORMAT JSON) SELECT id FROM public.direct_order_messages
 WHERE attachment_storage_path='{proof_path}'""")
print('PROOF_PATH_EXPLAIN=' + json.dumps(json.loads(plan)[0]), flush=True)
