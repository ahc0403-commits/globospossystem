#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
db_name="pos-report-ready-test-$$"
ledger_tmp="$(mktemp -d)"
cleanup() { docker rm -f "$db_name" >/dev/null 2>&1 || true; rm -rf "$ledger_tmp"; }
trap cleanup EXIT
# Only an owned disposable database; no production credentials or host ports.
docker run --detach --rm --name "$db_name" \
  --env POSTGRES_PASSWORD=report-fixture --env POSTGRES_DB=report_ready_test \
  public.ecr.aws/supabase/postgres:17.6.1.104 -c track_functions=all >/dev/null
for attempt in $(seq 1 60); do
  if docker exec "$db_name" pg_isready -h 127.0.0.1 -U postgres -d report_ready_test >/dev/null 2>&1; then break; fi
  if [[ "$attempt" == 60 ]]; then exit 1; fi
  sleep 1
done
run_sql() { docker exec -i "$db_name" psql -X -v ON_ERROR_STOP=1 -U postgres -d report_ready_test "$@"; }
docker exec --env PGPASSWORD=report-fixture "$db_name" psql -X -v ON_ERROR_STOP=1 -U supabase_admin -d report_ready_test \
  -c 'ALTER DATABASE report_ready_test OWNER TO postgres' >/dev/null
run_sql < test/fixtures/restaurant_sales_report_ready.sql >/dev/null
for attempt in 1 2; do
  run_sql < supabase/migrations/20260904120000_restaurant_sales_report_ready_at_2200.sql >/dev/null
  run_sql < test/sql/restaurant_sales_report_ready_test.sql >/dev/null
done
# Preserve the current VAT export fields before applying the clock-only fix.
run_sql <<'SQL' >/dev/null
ALTER TABLE order_items ADD COLUMN item_type text DEFAULT 'menu_item';
DO $$
DECLARE definition text;
BEGIN
  SELECT pg_get_functiondef('get_restaurant_daily_sales_exports_by_tax_entity(date)'::regprocedure) INTO definition;
  EXECUTE replace(definition, '''quantity'', item.quantity,', '''item_type'', item.item_type, ''quantity'', item.quantity,');
END $$;
SQL
run_sql < supabase/migrations/20260906140000_restaurant_sales_report_anytime.sql >/dev/null
run_sql < test/sql/restaurant_sales_report_anytime_test.sql >/dev/null
for attempt in 1 2; do
  run_sql < supabase/migrations/20261005060000_restaurant_sales_report_sample_exclusion.sql >/dev/null
  run_sql < test/sql/restaurant_sales_report_sample_exclusion_test.sql >/dev/null
done
docker exec --env PGPASSWORD=report-fixture "$db_name" psql -X -v ON_ERROR_STOP=1 -U supabase_admin -d report_ready_test -c 'GRANT USAGE ON SCHEMA auth TO postgres; GRANT EXECUTE ON FUNCTION pg_catalog.pg_stat_reset(),pg_catalog.pg_stat_force_next_flush() TO postgres;' >/dev/null
run_sql <<'SQL' >/dev/null
SET request.jwt.claim.sub='00000000-0000-0000-0000-000000000001';
ALTER TABLE payments ADD COLUMN id uuid DEFAULT gen_random_uuid(), ADD COLUMN combined_payment_group_id uuid;
CREATE TABLE digital_receipts(id uuid DEFAULT gen_random_uuid(),order_id uuid,restaurant_id uuid,combined_payment_group_id uuid,receipt_number text,created_at timestamptz DEFAULT now());
INSERT INTO digital_receipts(order_id,restaurant_id,receipt_number) VALUES('30000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','BC-20260904-000001');
CREATE TABLE meinvoice_tax_entity_config(tax_entity_id uuid PRIMARY KEY,payment_method_mixed text,payment_method_cash text,payment_method_card text,payment_method_pay text);
INSERT INTO meinvoice_tax_entity_config VALUES('10000000-0000-0000-0000-000000000001','TM','TM','TM','TM');
SQL
run_sql < supabase/migrations/20261010054000_pos_receipt_ledger.sql
run_sql < test/sql/restaurant_sales_report_sample_exclusion_test.sql
run_sql < test/sql/pos_receipt_ledger_test.sql
run_sql <<'SQL' >/dev/null
SELECT pg_stat_reset();
SQL
run_sql <<'SQL' >/dev/null
SET request.jwt.claim.sub='00000000-0000-0000-0000-000000000001';
SELECT pos_receipt_ledger_batch('2026-09-07','10000000-0000-0000-0000-000000000001',ARRAY(SELECT md5('ledger-1000-'||i)::uuid FROM generate_series(1,50) i),false) IS NOT NULL;
SELECT pg_stat_force_next_flush();
SQL
ledger_calls="$(docker exec "$db_name" psql -X -U postgres -d report_ready_test -Atqc "SELECT COALESCE(sum(calls),0) FROM pg_stat_user_functions WHERE funcname='meinvoice_payment_method_label';")"
[[ "$ledger_calls" == "0" ]] || { printf 'POS_LEDGER_N_PLUS_ONE calls=%s\n' "$ledger_calls"; exit 1; }
ledger_batch_calls="$(docker exec "$db_name" psql -X -U postgres -d report_ready_test -Atqc "SELECT COALESCE(sum(calls),0) FROM pg_stat_user_functions WHERE funcname='pos_receipt_ledger_batch';")"
[[ "$ledger_batch_calls" == "1" ]] || { printf 'POS_LEDGER_BATCH_CALL_COUNT=%s\n' "$ledger_batch_calls"; exit 1; }
printf 'POS_LEDGER_PER_RECEIPT_FUNCTION_CALLS=%s\n' "$ledger_calls"
ledger_query="SET request.jwt.claim.sub='00000000-0000-0000-0000-000000000001'; WITH response AS MATERIALIZED(SELECT pos_receipt_ledger_batch('2026-09-07','10000000-0000-0000-0000-000000000001',ARRAY(SELECT md5('ledger-1000-'||i)::uuid FROM generate_series(1,50) i),false) v) SELECT jsonb_array_length(v->'rows'),octet_length(v::text) FROM response; SELECT pg_stat_force_next_flush();"
docker exec "$db_name" psql -X -At -U postgres -d report_ready_test -v ON_ERROR_STOP=1 -c "$ledger_query" > "$ledger_tmp/one.log" 2>&1 &
ledger_one=$!
docker exec "$db_name" psql -X -At -U postgres -d report_ready_test -v ON_ERROR_STOP=1 -c "$ledger_query" > "$ledger_tmp/two.log" 2>&1 &
ledger_two=$!
wait "$ledger_one" || { cat "$ledger_tmp/one.log"; exit 1; }
wait "$ledger_two" || { cat "$ledger_tmp/two.log"; exit 1; }
rg -q '^50\|' "$ledger_tmp/one.log"
rg -q '^50\|' "$ledger_tmp/two.log"
ledger_total="$(docker exec "$db_name" psql -X -U postgres -d report_ready_test -Atqc "SELECT COALESCE(sum(calls),0) FROM pg_stat_user_functions WHERE funcname='pos_receipt_ledger_batch';")"
[[ "$ledger_total" == "3" ]] || { printf 'POS_LEDGER_CONCURRENT_CALL_COUNT=%s\n' "$ledger_total"; exit 1; }
printf 'POS_LEDGER_CONCURRENT_READS=PASS sessions=2 rows_per_response=50 rpc_per_session=1\n'
printf 'POS_LEDGER_SQL_TEST=PASS\n' 
