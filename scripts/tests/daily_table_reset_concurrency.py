"""Exercise reset/payment and reset/QR lock ordering in independent sessions."""
import json
import subprocess
import sys

port = sys.argv[1]
cmd = ["psql", "-X", "-qAt", "-h", "127.0.0.1", "-p", port, "-U", "postgres", "-d", "postgres", "-v", "ON_ERROR_STOP=1"]
claims = "SET request.jwt.claim.role='service_role'; SET request.jwt.claim.sub='91000000-0000-4000-8000-000000000003';"


def query(sql):
    return subprocess.run(cmd, input=claims + sql, text=True, capture_output=True, check=True, timeout=10).stdout.strip()


def locked_process(sql, marker):
    proc = subprocess.Popen(cmd, text=True, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=1)
    proc.stdin.write(claims + sql)
    proc.stdin.close()
    proc.stdin = None
    while True:
        line = proc.stdout.readline()
        if not line:
            raise RuntimeError(proc.stderr.read())
        if line.strip() == marker:
            return proc


query("UPDATE table_operational_reset_policies SET is_enabled=false; SELECT test_seed_reset_order(100,0,'serving',0,16); UPDATE table_operational_reset_policies SET is_enabled=true,last_attempt_at=NULL;")
payment = locked_process("""
BEGIN;
SELECT id FROM orders WHERE id=test_uuid(2100) FOR UPDATE;
SELECT 'PAYMENT_LOCKED';
SELECT pg_sleep(1);
INSERT INTO payments(order_id,restaurant_id,amount) VALUES(test_uuid(2100),test_uuid(1),40);
COMMIT;
""", "PAYMENT_LOCKED")
future = "((now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date+1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh'"
first = json.loads(query(f"SELECT close_expired_table_operations_at(test_uuid(1),{future});"))
assert first["pending"], "reset should retry an order locked by payment"
out, err = payment.communicate(timeout=5)
assert payment.returncode == 0, err
query(f"SELECT close_expired_table_operations_at(test_uuid(1),{future});")
query("""SELECT test_assert((SELECT closure_kind='financial_review' AND paid_total=40 FROM order_operational_closures WHERE order_id=test_uuid(2100)),'retry sees committed partial payment');
SELECT test_assert((SELECT count(*)=1 AND sum(amount)=40 FROM payments WHERE order_id=test_uuid(2100)),'payment was not deleted or duplicated');""")

query("INSERT INTO table_qr_tokens(restaurant_id,table_id,token) VALUES(test_uuid(1),test_uuid(117),'concurrent-qr');")
cart = """'[{"menu_item_id":"91000000-0000-4000-8000-000000000011","quantity":1}]'"""
winner = locked_process(f"""
BEGIN;
SELECT id FROM tables WHERE id=test_uuid(117) FOR UPDATE;
SELECT 'TABLE_LOCKED';
SELECT pg_sleep(1);
SELECT qr_place_order('concurrent-qr',{cart},test_uuid(6001),true,NULL);
COMMIT;
""", "TABLE_LOCKED")
loser = subprocess.run(cmd, input=claims + f"SELECT qr_place_order('concurrent-qr',{cart},test_uuid(6002),true,NULL);", text=True, capture_output=True, timeout=5)
out, err = winner.communicate(timeout=5)
assert winner.returncode == 0, err
assert loser.returncode != 0 and "QR_ORDER_CONTEXT_CHANGED" in loser.stderr, loser.stderr
query("SELECT test_assert((SELECT count(*)=1 FROM orders WHERE table_id=test_uuid(117) AND status IN ('pending','confirmed','serving')),'concurrent requests create one table order');")

query("SELECT test_seed_reset_order(101,0,'serving',0,18);")
closing = locked_process(f"""
BEGIN;
SELECT id FROM orders WHERE id=test_uuid(2101) FOR UPDATE;
SELECT 'CLOSURE_LOCKED';
SELECT pg_sleep(1);
SELECT close_expired_table_operations_at(test_uuid(1),{future});
COMMIT;
""", "CLOSURE_LOCKED")
late = subprocess.run(cmd, input=claims + "UPDATE order_items SET status='ready' WHERE id=test_uuid(3101);", text=True, capture_output=True, timeout=5)
out, err = closing.communicate(timeout=5)
assert closing.returncode == 0, err
assert late.returncode != 0 and "could not obtain lock on row in relation" in late.stderr, late.stderr
query("SELECT test_assert((SELECT status='cancelled' FROM order_items WHERE id=test_uuid(3101)),'late station write cannot race parent closure');")
print("DAILY_TABLE_RESET_CONCURRENCY=PASS")
