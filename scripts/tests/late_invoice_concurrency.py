"""Race real SQL functions in an owned local fixture, without production access."""
import concurrent.futures
import subprocess
import sys

container = sys.argv[1]
base = ['docker', 'exec', '-i', container, 'psql', '-X', '-At', '-v',
        'ON_ERROR_STOP=1', '-U', 'postgres', '-d', 'late_invoice']
actor = "SET request.jwt.claim.sub='00000000-0000-4000-8000-000000000001';"


def sql(query):
    return subprocess.run(base, input=actor + query, text=True, capture_output=True)


for n, same in [(1000, True), (1001, False)]:
    assert sql(f'SELECT late_fixture.sale({n});').returncode == 0
    calls = []
    for worker in range(2):
        request = f"md5('race-{n}-{0 if same else worker}')::uuid"
        calls.append(f"SELECT pos_submit_late_invoice({request},late_fixture.shop(1),"
                     f"md5('late-order-{n}')::uuid,NULL,jsonb_build_object(md5('late-order-{n}')::uuid,NULL),late_fixture.patch(),true)->>'state';")
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
        results = list(executor.map(sql, calls))
    successes = sum(r.returncode == 0 for r in results)
    assert successes == (2 if same else 1), [r.stderr for r in results]
    if not same:
        assert any('POS_BUYER_CHANGED' in r.stderr for r in results)
    assert sql(f"SELECT count(*) FROM meinvoice_jobs WHERE order_id=md5('late-order-{n}')::uuid;").stdout.strip().endswith('1')
    print(f'LATE_INVOICE_CONCURRENCY same_request={same} successes={successes} jobs=1')

assert sql("SELECT late_fixture.sale(1002); INSERT INTO meinvoice_jobs(order_id,store_id,tax_entity_id) VALUES(md5('late-order-1002')::uuid,late_fixture.shop(1),md5('late-tax')::uuid);").returncode == 0
dispatcher = subprocess.Popen(base, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, text=True)
dispatcher.stdin.write(actor + "BEGIN; UPDATE meinvoice_jobs SET dispatch_claim_id=gen_random_uuid() WHERE order_id=md5('late-order-1002')::uuid;\n\\echo LOCKED\nSELECT pg_sleep(1); COMMIT;\n")
dispatcher.stdin.close()
while True:
    line = dispatcher.stdout.readline()
    if 'LOCKED' in line:
        break
    assert line, dispatcher.stderr.read()
result = sql("SELECT pos_submit_late_invoice(gen_random_uuid(),late_fixture.shop(1),md5('late-order-1002')::uuid,NULL,jsonb_build_object(md5('late-order-1002')::uuid,NULL),late_fixture.patch(),true);")
assert result.returncode != 0 and 'LATE_INVOICE_PROTECTED' in result.stderr, result.stderr
assert dispatcher.wait() == 0
assert sql("SELECT count(*) FROM red_invoice_intakes WHERE order_id=md5('late-order-1002')::uuid;").stdout.strip().endswith('0')
print('LATE_INVOICE_DISPATCH_RACE=PASS no_intake_or_second_invoice')


def protect_while_submitting(n, protection):
    assert sql(f'SELECT late_fixture.sale({n});').returncode == 0
    owner = subprocess.Popen(base, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, text=True)
    owner.stdin.write(actor + 'BEGIN; ' + protection +
                      '\n\\echo LOCKED\nSELECT pg_sleep(1); COMMIT;\n')
    owner.stdin.close()
    while True:
        line = owner.stdout.readline()
        if 'LOCKED' in line:
            break
        assert line, owner.stderr.read()
    result = sql(f"SELECT pos_submit_late_invoice(gen_random_uuid(),late_fixture.shop(1),md5('late-order-{n}')::uuid,NULL,jsonb_build_object(md5('late-order-{n}')::uuid,NULL),late_fixture.patch(),true);")
    assert result.returncode != 0 and 'LATE_INVOICE_PROTECTED' in result.stderr, result.stderr
    assert owner.wait() == 0
    assert sql(f"SELECT count(*) FROM red_invoice_intakes WHERE order_id=md5('late-order-{n}')::uuid;").stdout.strip().endswith('0')


protect_while_submitting(1003, "SELECT id FROM payments WHERE order_id=md5('late-order-1003')::uuid FOR UPDATE; INSERT INTO payment_adjustments(payment_id,amount) SELECT id,1 FROM payments WHERE order_id=md5('late-order-1003')::uuid;")
print('LATE_INVOICE_REFUND_RACE=PASS original_refund_protected')
protect_while_submitting(1004, "SELECT pg_advisory_xact_lock(hashtextextended('sales-reporting:'||md5('late-tax')::uuid::text||':'||(now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date::text,0)); INSERT INTO sales_reporting_claims VALUES('restaurant_pos',md5('late-order-1004')::uuid::text,gen_random_uuid());")
print('LATE_INVOICE_REPORTING_RACE=PASS confirmed_member_protected')
