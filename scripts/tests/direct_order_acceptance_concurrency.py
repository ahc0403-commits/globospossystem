"""Actual row-lock retry races and bounded attachment responses in an isolated DB."""
import concurrent.futures
import json
import statistics
import subprocess
import sys
import threading
import time

container = sys.argv[1]
assert container.startswith('globos-direct-fallback-test-')
claims = "SET request.jwt.claim.sub='00000000-0000-4000-8000-000000000001';" + \
    "SET request.jwt.claims='" + json.dumps({'sub': '00000000-0000-4000-8000-000000000001', 'role': 'authenticated'}) + "';"


def sql(statement):
    result = subprocess.run(['docker', 'exec', container, 'psql', '-X', '-qAt', '-U', 'postgres',
                             '-d', 'codex_direct_photo', '-v', 'ON_ERROR_STOP=1', '-c', claims + statement],
                            capture_output=True, text=True)
    return result


def checked(statement):
    result = sql(statement)
    if result.returncode:
        raise RuntimeError(result.stderr)
    return result.stdout.strip()


f = json.loads(checked("SELECT proof_test.scope(false)"))
rid, shop = f['request_id'], f['store_id']
checked(f"UPDATE public.direct_order_requests SET customer_note='Accepted original fixture' WHERE id='{rid}'")
q = json.loads(checked(f"SELECT jsonb_build_object('id',id,'version',version) FROM public.direct_order_customer_requirements WHERE request_id='{rid}' AND source_kind='order'"))
mutation = checked('SELECT gen_random_uuid()')
call = f"SELECT public.direct_order_staff_accept_requirement('{shop}','{rid}','{q['id']}',{q['version']},'{mutation}')"
barrier = threading.Barrier(2)


def retry(_):
    barrier.wait(timeout=20)
    return sql(call)


with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    results = list(pool.map(retry, range(2)))
assert all(r.returncode == 0 for r in results), [r.stderr for r in results]
assert checked(f"SELECT count(*) FROM public.direct_order_messages WHERE request_id='{rid}' AND metadata->>'requirement_mutation_id'='{mutation}'") == '1'
print('REQUEST_ACCEPT_RETRY_RACE=PASS winners=1 messages=1')

# A concurrent source edit must leave the NEW source unanswered, irrespective of lock order.
checked(f"UPDATE public.direct_order_requests SET customer_note='Before source race fixture' WHERE id='{rid}'")
q = json.loads(checked(f"SELECT jsonb_build_object('id',id,'version',version) FROM public.direct_order_customer_requirements WHERE request_id='{rid}' AND source_kind='order'"))
barrier = threading.Barrier(2)
statements = [f"SELECT public.direct_order_staff_accept_requirement('{shop}','{rid}','{q['id']}',{q['version']},gen_random_uuid())",
              f"UPDATE public.direct_order_requests SET customer_note='After source race fixture' WHERE id='{rid}'"]


def race(statement):
    barrier.wait(timeout=20)
    return sql(statement)


with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    results = list(pool.map(race, statements))
assert results[1].returncode == 0, results[1].stderr
assert results[0].returncode == 0 or 'DIRECT_ORDER_REQUIREMENT_VERSION_CONFLICT' in results[0].stderr
assert checked(f"SELECT status||':'||request_text FROM public.direct_order_customer_requirements WHERE id='{q['id']}'") == 'awaiting_reply:After source race fixture'
print('REQUEST_ACCEPT_SOURCE_RACE=PASS stale_acceptance_cannot_confirm_new_source')

for count in [1, 20, 100]:
    checked(f"INSERT INTO public.direct_order_messages(request_id,restaurant_id,sender_type,message_type,body) SELECT '{rid}','{shop}','customer','text',repeat('fixture',20) FROM generate_series(1,{count})")
    measure = json.loads(checked(f"SELECT jsonb_build_object('context_bytes',octet_length(public.direct_order_staff_attachment_context('{shop}','{rid}')::text),'detail_bytes',octet_length(public.direct_order_staff_detail_v8('{shop}','{rid}')::text))"))
    assert measure['context_bytes'] < 64 < measure['detail_bytes']
    print('ATTACHMENT_BOUNDED_RESPONSE=' + json.dumps({'added_messages': count, **measure}))

for clients in [1, 10, 50]:
    def read(_):
        start = time.monotonic()
        raw = checked(f"SELECT public.direct_order_staff_attachment_context('{shop}','{rid}')")
        assert json.loads(raw)['support']['chat_open'] is True
        return (time.monotonic() - start) * 1000
    with concurrent.futures.ThreadPoolExecutor(max_workers=clients) as pool:
        durations = sorted(pool.map(read, range(clients)))
    print('ATTACHMENT_CONTEXT_CONCURRENCY=' + json.dumps({'clients': clients, 'rpc_calls': clients,
        'context_bytes': measure['context_bytes'], 'p50_ms': statistics.median(durations),
        'p95_ms': durations[min(len(durations)-1, int(len(durations)*.95))],
        'transport': 'local Docker CLI plus SQL; not production network latency'}))
