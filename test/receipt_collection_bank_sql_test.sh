#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
qr_db_name="pos-receipt-bank-test-$$"
cleanup() { docker rm -f "$qr_db_name" >/dev/null 2>&1 || true; }
trap cleanup EXIT
docker run --detach --rm --name "$qr_db_name" \
  --env POSTGRES_PASSWORD=receipt-fixture --env POSTGRES_DB=receipt_bank_test \
  public.ecr.aws/supabase/postgres:17.6.1.104 >/dev/null
for attempt in $(seq 1 60); do
  if docker exec "$qr_db_name" pg_isready -h 127.0.0.1 -U postgres -d receipt_bank_test >/dev/null 2>&1; then break; fi
  if [[ "$attempt" == 60 ]]; then exit 1; fi
  sleep 1
done
run_sql() { docker exec -i "$qr_db_name" psql -X -v ON_ERROR_STOP=1 -U postgres -d receipt_bank_test; }
docker exec --env PGPASSWORD=receipt-fixture "$qr_db_name" psql -X -v ON_ERROR_STOP=1 -U supabase_admin -d receipt_bank_test \
  -c 'ALTER DATABASE receipt_bank_test OWNER TO postgres' >/dev/null
run_sql < test/fixtures/receipt_collection_bank.sql >/dev/null
# Exercise the actual existing function, rather than a copy of its behavior.
python3 - <<'PY' | run_sql >/dev/null
from pathlib import Path
s=Path('supabase/migrations/20260722120000_cash_tender_and_protected_alcohol_vat.sql').read_text()
start=s.index('CREATE OR REPLACE FUNCTION public.enrich_cashier_receipt_payload()')
end=s.index('CREATE OR REPLACE FUNCTION public.enqueue_cash_receipt_print_job(', start)
print(s[start:end])
PY
run_sql <<'SQL' >/dev/null
CREATE TRIGGER enrich_cashier_receipt_payload_trigger BEFORE INSERT OR UPDATE OF payload ON print_jobs
FOR EACH ROW EXECUTE FUNCTION enrich_cashier_receipt_payload();
INSERT INTO print_jobs(id,copy_type,order_id,payload) VALUES
('40000000-0000-0000-0000-000000000099','receipt','30000000-0000-0000-0000-000000000001','{"total_amount":100000}');
SQL
# Applying twice verifies idempotence; existing records are never backfilled.
run_sql < supabase/migrations/20261012183000_receipt_collection_bank.sql >/dev/null
run_sql < supabase/migrations/20261012183000_receipt_collection_bank.sql >/dev/null
run_sql < test/sql/receipt_collection_bank_test.sql
printf 'RECEIPT_COLLECTION_BANK_SQL_TEST=PASS\n'
