"""Two real DB connections race activation against order intake in a local fixture."""
import concurrent.futures
import subprocess
import sys
import time

command = ["docker", "exec", "-i", "--env", "PGPASSWORD=fixture-only", sys.argv[1], "psql", "-X", "-At", "-U", "supabase_admin", "-d", "postgres", "-v", "ON_ERROR_STOP=1"]
actor = "SELECT set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000099',true);"
def run(statement, check=True):
    return subprocess.run(command, input=statement, text=True, capture_output=True, check=check, timeout=20)

def wait_for_lock(application):
    for _ in range(100):
        if run(f"SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE application_name='{application}' AND wait_event_type='Lock');").stdout.strip() == 't':
            return
        time.sleep(0.05)
    raise AssertionError(f"No observed lock wait for {application}")

store, revision, release = run("SELECT store_id,revision,candidate_id FROM operating_test.workflow_concurrency;").stdout.strip().split('|')
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    # Intake holds the shared boundary while activation waits for its exclusive lock.
    intake = pool.submit(run, f"SET application_name='workflow_intake_first'; BEGIN; {actor} INSERT INTO public.orders(restaurant_id,status,notes) VALUES('{store}','pending','workflow-concurrency-first'); SELECT pg_sleep(3); COMMIT;")
    # Observe the actual uncommitted transaction, not a fixed guess at start order.
    for _ in range(100):
        if run("SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE application_name='workflow_intake_first' AND wait_event='PgSleep');").stdout.strip() == 't': break
        time.sleep(0.02)
    else: raise AssertionError("Intake never acquired its transaction lock")
    activate = pool.submit(run, f"SET application_name='workflow_activation_wait'; BEGIN; {actor} SELECT public.admin_store_workflow_v1('{store}','activate',{revision}); COMMIT;", False)
    wait_for_lock('workflow_activation_wait')
    intake.result()
    rejected = activate.result()
    assert rejected.returncode != 0 and 'WORKFLOW_DRAIN_REQUIRED' in rejected.stderr, rejected.stderr
    run(f"BEGIN; {actor} UPDATE public.orders SET status='cancelled' WHERE notes='workflow-concurrency-first'; COMMIT;")
    # Activation wins the same boundary: the waiting intake must capture its release.
    activate = pool.submit(run, f"SET application_name='workflow_activate_first'; BEGIN; {actor} SELECT public.admin_store_workflow_v1('{store}','activate',{revision}); SELECT pg_sleep(3); COMMIT;")
    for _ in range(100):
        if run("SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE application_name='workflow_activate_first' AND wait_event='PgSleep');").stdout.strip() == 't': break
        time.sleep(0.02)
    else: raise AssertionError("Activation never acquired its transaction lock")
    intake = pool.submit(run, f"SET application_name='workflow_intake_wait'; BEGIN; {actor} INSERT INTO public.orders(restaurant_id,status,notes) VALUES('{store}','pending','workflow-concurrency-after'); COMMIT;")
    wait_for_lock('workflow_intake_wait')
    activate.result()
    intake.result()
    actual = run("SELECT operating_release_id FROM public.orders WHERE notes='workflow-concurrency-after';").stdout.strip()
    assert actual == release, (actual, release)
print('WORKFLOW_INTAKE_ACTIVATION_CONCURRENCY=PASS both lock orders, rejected undrained activation, immutable new-order release')
