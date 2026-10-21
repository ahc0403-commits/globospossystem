"""Two independent PostgreSQL transactions capture the same reviewed revision."""
import concurrent.futures
import json
import subprocess
import sys
import threading


container = sys.argv[1]
command = [
    "docker", "exec", "-i", "--env", "PGPASSWORD=fixture-only", container,
    "psql", "-X", "-At", "-U", "postgres", "-v", "ON_ERROR_STOP=1",
]
shop = "8bc9eef5-dcd5-46b1-b931-23f77132322c"
subprocess.run(
    command, input=f"UPDATE public.tables SET table_number='race-'||table_number WHERE restaurant_id='{shop}';",
    text=True, capture_output=True, check=True, timeout=15,
)
barrier = threading.Barrier(2)


def capture():
    barrier.wait(timeout=10)
    result = subprocess.run(
        command,
        input=f"""BEGIN;
SELECT set_config('request.jwt.claim.sub','e2000000-0000-4000-8000-000000000001',true);
SET LOCAL ROLE authenticated;
SELECT public.admin_capture_store_operating_baseline_v1('{shop}',1);
SELECT pg_sleep(0.25);
COMMIT;
""",
        text=True, capture_output=True, check=True, timeout=15,
    )
    return next(json.loads(line) for line in result.stdout.splitlines() if line.startswith("{"))


with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    futures = [pool.submit(capture) for _ in range(2)]
    first, second = [future.result() for future in futures]
assert first == second and first["revision"] == 2, (first, second)
result = subprocess.run(
    command,
    input=f"SELECT count(*) FROM public.store_operating_versions WHERE restaurant_id='{shop}';",
    text=True, capture_output=True, check=True, timeout=15,
)
assert result.stdout.strip() == "2", result.stdout
print("OPERATING_PROFILE_CONCURRENT_CAPTURE=PASS same version, no duplicate assignments")
