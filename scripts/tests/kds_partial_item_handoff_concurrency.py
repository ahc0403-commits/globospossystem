"""Concurrent replay probes against the synthetic, network-isolated fixture."""
import concurrent.futures
import json
import subprocess
import sys

container = sys.argv[1]
assert container.startswith("pos-kds-partial-")

def sql(query):
    result = subprocess.run(
        ["docker", "exec", "-i", container, "psql", "-X", "-U", "postgres",
         "-v", "ON_ERROR_STOP=1", "-Atq"],
        input=query, text=True, capture_output=True, check=True)
    return result.stdout.strip()

def actor(query):
    return sql("SELECT set_config('request.jwt.claim.sub',test_uuid(101)::text,false);\n"
               + query).splitlines()[-1]

for clients in (2, 20):
    seed = 900000 + clients
    sql(f"SELECT test_line({seed},{clients+1},{clients+1},{clients},{clients});")
    command = (f"SELECT kds_serve_ready_order_v3(test_uuid({seed+20000}),"
               f"test_uuid({seed+40000}));")
    with concurrent.futures.ThreadPoolExecutor(max_workers=clients) as pool:
        responses = list(pool.map(lambda _: json.loads(actor(command)), range(clients)))
    assert sum(not r["deduplicated"] for r in responses) == 1
    assert sum(r["deduplicated"] for r in responses) == clients-1
    assert sql(f"SELECT floor_served_quantity FROM emergency_fulfillment_items WHERE id=test_uuid({seed});") == str(clients)
    assert sql(f"SELECT count(*) FROM emergency_fulfillment_events WHERE details->>'batch_request_id'=test_uuid({seed+40000})::text;") == "1"
    print(f"CONCURRENT_BULK clients={clients} mutations=1 duplicates={clients-1}")

    seed += 100
    sql(f"SELECT test_line({seed},{clients+1},{clients+1},{clients},{clients});")
    command = (f"SELECT kds_record_station_progress_v3(test_uuid({seed}),"
               f"'base','floor_served',1,test_uuid({seed+40000}));")
    with concurrent.futures.ThreadPoolExecutor(max_workers=clients) as pool:
        responses = list(pool.map(lambda _: json.loads(actor(command)), range(clients)))
    assert sum(not r["deduplicated"] for r in responses) == 1
    assert sql(f"SELECT floor_served_quantity FROM emergency_fulfillment_items WHERE id=test_uuid({seed});") == "1"
    print(f"CONCURRENT_SINGLE_REPLAY clients={clients} mutations=1 duplicates={clients-1}")

    seed += 100
    sql(f"SELECT test_line({seed},{clients+1},{clients+1},{clients},{clients});")
    def distinct(index):
        return json.loads(actor(
            f"SELECT kds_record_station_progress_v3(test_uuid({seed}),"
            f"'base','floor_served',1,test_uuid({seed+40000+index}));"))
    with concurrent.futures.ThreadPoolExecutor(max_workers=clients) as pool:
        responses = list(pool.map(distinct, range(clients)))
    assert all(not r["deduplicated"] for r in responses)
    assert sql(f"SELECT floor_served_quantity FROM emergency_fulfillment_items WHERE id=test_uuid({seed});") == str(clients)
    print(f"CONCURRENT_SINGLE_DISTINCT clients={clients} served={clients} lost_updates=0")
