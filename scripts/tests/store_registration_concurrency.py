"""Isolated DB races: one request creates one store; distinct requests get unique IDs."""
import concurrent.futures
import json
import subprocess
import sys
import time
import uuid

command = ['docker', 'exec', '-i', '--env', 'PGPASSWORD=fixture-only', sys.argv[1], 'psql', '-X', '-At', '-U', 'supabase_admin', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1']
actor = "SELECT set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000099',true);"
def run(sql):
    result = subprocess.run(command, input=sql, text=True, capture_output=True, timeout=30)
    if result.returncode:
        raise AssertionError(result.stderr)
    return result.stdout.strip().splitlines()

run("UPDATE public.brands SET short_code='LAB' WHERE id='91000000-0000-4000-8000-000000000003';")
request = str(uuid.uuid4())
body = json.dumps({'name': 'Registration concurrent branch', 'brand': '91000000-0000-4000-8000-000000000003', 'entity': '91000000-0000-4000-8000-000000000004'})
started = time.monotonic()
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    replies = list(pool.map(run, [f"BEGIN; {actor} SELECT public.admin_register_store_v1('{request}','{body}'::jsonb); COMMIT;"] * 4))
store_ids = {next(line for line in reply if len(line) == 36 and line != '92000000-0000-4000-8000-000000000099') for reply in replies}
assert len(store_ids) == 1, replies
assert run(f"SELECT count(*) FROM public.store_account_onboarding_jobs WHERE id='{request}';")[-1] == '1'
requests = [str(uuid.uuid4()) for _ in range(8)]
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    codes = list(pool.map(run, [f"BEGIN; {actor} SELECT public.admin_reserve_store_code_v1('{r}'); COMMIT;" for r in requests]))
allocated = {next(line for line in reply if line.startswith('ST') and len(line) == 6) for reply in codes}
assert len(allocated) == 8, codes
print(f'STORE_REGISTRATION_CONCURRENCY=PASS same_request_calls=4 stores=1 distinct_codes=8 concurrency=4 elapsed_ms={round((time.monotonic()-started)*1000)}')
