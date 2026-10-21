"""Real concurrent payments sharing two stock rows in the full-schema fixture."""
import concurrent.futures
import subprocess
import sys
import threading


command = [
    "docker", "exec", "-i", "--env", "PGPASSWORD=fixture-only", sys.argv[1],
    "psql", "-X", "-At", "-U", "supabase_admin", "-d", "postgres", "-v", "ON_ERROR_STOP=1",
]


def sql(statement):
    return subprocess.run(
        command, input=statement, text=True, capture_output=True, check=True, timeout=20,
    ).stdout.strip()


scope = [row.split("|") for row in sql(
    "SELECT order_id,store_id FROM operating_test.concurrent_payments ORDER BY order_id;"
).splitlines()]
assert len(scope) == 2, scope
barrier = threading.Barrier(2)


def pay(row):
    order, store = row
    barrier.wait(timeout=10)
    sql(f"""BEGIN;
SELECT set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000099',true);
SELECT public.process_payment('{order}','{store}',10800,'CASH');
SELECT pg_sleep(0.25);
COMMIT;
""")


with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    list(pool.map(pay, scope))
sql("""DO $$ BEGIN
 ASSERT NOT EXISTS(SELECT 1 FROM operating_test.concurrent_stock s JOIN inventory_items i ON i.id=s.id WHERE i.current_stock<>s.expected), 'lost concurrent stock update';
 ASSERT (SELECT count(*)=2 AND sum(amount)=21600 FROM payments WHERE order_id IN(SELECT order_id FROM operating_test.concurrent_payments)), 'payment count mismatch';
 ASSERT (SELECT count(*)=4 AND sum(quantity_g)=-26 FROM inventory_transactions WHERE reference_id IN(SELECT i.id FROM order_items i JOIN operating_test.concurrent_payments p ON p.order_id=i.order_id)), 'concurrent journal mismatch';
END $$;""")
print("OPERATING_PAYMENT_CONCURRENCY=PASS two orders, shared ingredients, exact stock and journal")
