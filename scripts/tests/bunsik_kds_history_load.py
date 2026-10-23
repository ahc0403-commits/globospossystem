"""Bounded HTTP load against disposable, schema-only POS fixtures.

No production access. JWTs use a fixture-only signing key and synthetic users.
Each simulated terminal owns exactly two sequential read lanes.
"""
import argparse
import base64
import concurrent.futures
import hashlib
import hmac
import json
import math
import pathlib
import random
import threading
import time
import urllib.request
import urllib.error

parser = argparse.ArgumentParser()
parser.add_argument("url")
parser.add_argument("output", type=pathlib.Path)
parser.add_argument("--rounds", type=int, default=5)
parser.add_argument("--historical", type=int, default=4463)
parser.add_argument("--today", type=int, default=300)
args = parser.parse_args()
if not args.url.startswith("http://127.0.0.1:"):
    raise SystemExit("Only a loopback fixture endpoint is allowed")


def token(actor):
    encode = lambda x: base64.urlsafe_b64encode(json.dumps(x, separators=(",", ":")).encode()).rstrip(b"=")
    header = encode({"alg": "HS256", "typ": "JWT"})
    payload = encode({"role": "authenticated", "sub": f"ba000000-0000-4000-8000-{900020+actor:012}",
                     "exp": int(time.time()) + 3600,
                     "accessible_store_ids": ["8bc9eef5-dcd5-46b1-b931-23f77132322c"]})
    message = header + b"." + payload
    signature = base64.urlsafe_b64encode(hmac.new(
        b"bunsik-isolated-jwt-secret-for-local-load-test", message, hashlib.sha256).digest()).rstrip(b"=")
    return (message + b"." + signature).decode()


def rpc(name, body, actor):
    request = urllib.request.Request(args.url + "/rpc/" + name, data=json.dumps(body).encode(),
                                    headers={"Content-Type": "application/json",
                                             "Authorization": "Bearer " + token(actor)})
    started = time.perf_counter()
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = response.read()
    except urllib.error.HTTPError as error:
        raise RuntimeError(f'{name}: HTTP {error.code}: {error.read().decode()[:600]}') from None
    elapsed = (time.perf_counter() - started) * 1000
    value = json.loads(payload)
    if name == "get_bunsik_kds_completed_page_v1" and len(value["orders"]) > body["p_limit"]:
        raise AssertionError("Page bound exceeded")
    return {"rpc": name, "ms": elapsed, "bytes": len(payload)}


def summary(rows):
    times = sorted(r["ms"] for r in rows)
    percentile = lambda p: round(times[max(0, math.ceil(len(times) * p) - 1)], 3)
    return {"requests": len(rows), "p50_ms": percentile(.5), "p95_ms": percentile(.95),
            "p99_ms": percentile(.99), "max_ms": round(times[-1], 3),
            "max_response_bytes": max(r["bytes"] for r in rows)}


# Warm every used role/path, including compilation, before recording load.
for actor in (1, 2, 3, 5):
    for name, body in (("get_kds_sync_config", {}), ("get_emergency_station_snapshot", {}),
                       ("get_bunsik_kds_completed_page_v1", {"p_limit": 50}),
                       ("get_emergency_station_timings", {})):
        rpc(name, body, actor)

result = {"historical_queues": args.historical, "today_queues": args.today,
          "line_distribution": {"mean": 4.45, "p95_approx": 9, "maximum": 15},
          "database": "PostgreSQL 17.6 production schema with synthetic rows",
          "limits": {"db_cpu": 2, "db_memory_mb": 2048, "postgrest_pool": 10,
                     "postgrest_cpu": 1, "postgrest_memory_mb": 512,
                     "history_page": 50, "read_lanes_per_terminal": 2},
          "runs": []}
for terminals in (4, 8, 40):
    barrier = threading.Barrier(terminals * 2)
    active = [0] * terminals
    maximum = [0] * terminals
    lock = threading.Lock()

    def lane(terminal, auxiliary):
        actor = (1, 2, 3, 5)[terminal % 4]
        names = [("get_bunsik_kds_completed_page_v1", {"p_limit": 50}),
                 ("get_emergency_station_timings", {})] if auxiliary else [
                     ("get_kds_sync_config", {}), ("get_emergency_station_snapshot", {})]
        rows = []
        barrier.wait()
        for iteration in range(args.rounds):
            for name, body in names:
                with lock:
                    active[terminal] += 1
                    maximum[terminal] = max(maximum[terminal], active[terminal])
                    assert active[terminal] <= 2
                try:
                    rows.append(rpc(name, body, actor))
                finally:
                    with lock:
                        active[terminal] -= 1
            time.sleep(random.Random(terminal * 100 + iteration).uniform(.02, .06))
        return rows

    started = time.perf_counter()
    with concurrent.futures.ThreadPoolExecutor(max_workers=terminals * 2) as pool:
        futures = [pool.submit(lane, terminal, auxiliary)
                   for terminal in range(terminals) for auxiliary in (False, True)]
        rows = [row for future in futures for row in future.result()]
    entry = {"terminals": terminals, "rounds": args.rounds,
             "duration_s": round(time.perf_counter() - started, 3),
             "errors": 0, "max_in_flight_per_terminal": max(maximum),
             "metrics": {name: summary([r for r in rows if r["rpc"] == name])
                         for name in sorted({r["rpc"] for r in rows})}}
    result["runs"].append(entry)
    print(json.dumps(entry, ensure_ascii=False), flush=True)

args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(result, indent=2) + "\n")
