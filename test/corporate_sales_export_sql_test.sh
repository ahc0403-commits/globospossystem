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
run_sql < test/fixtures/corporate_sales_export_setup.sql
run_sql < supabase/migrations/20261011080000_meinvoice_owned_batches.sql
if [[ "${CORPORATE_RELEASE_ATOMIC:-0}" == "1" ]]; then
  # A late failure must roll back every component, not leave a partial schema.
  state_query="SELECT md5(string_agg(pg_get_functiondef(to_regprocedure(signature)),signature ORDER BY signature)) FROM (VALUES ('public.direct_order_public_resume_storefront(uuid,text)'),('public.direct_order_admin_get_storefront(uuid)'),('public.enqueue_meinvoice_cash_register_job()'),('public.claim_meinvoice_jobs(uuid,integer,uuid)')) functions(signature)"
  before_state="$(run_sql -Atc "$state_query")"
  python3 - "$ledger_tmp/forced_failure.sql" <<'PYROLLBACK'
from pathlib import Path
import sys
source=Path('scripts/releases/20261011204000_corporate_sales_invoice_contacts_release.sql').read_text()
anchor=" RAISE NOTICE 'CORPORATE_SALES_CONTACTS_ATOMIC_RELEASE=PASS';"
assert source.count(anchor)==1
Path(sys.argv[1]).write_text(source.replace(anchor," RAISE EXCEPTION 'CORPORATE_TEST_FORCED_LATE_FAILURE';"))
PYROLLBACK
  if run_sql < "$ledger_tmp/forced_failure.sql" > "$ledger_tmp/rollback.log" 2>&1; then
    printf 'Forced atomic rollback unexpectedly succeeded\n' >&2; exit 1
  fi
  rg -q 'CORPORATE_TEST_FORCED_LATE_FAILURE' "$ledger_tmp/rollback.log"
  [[ "$(run_sql -Atc "$state_query")" == "$before_state" ]]
  [[ "$(run_sql -Atc "SELECT to_regclass('public.tax_entity_collection_accounts') IS NULL AND to_regclass('public.menu_invoice_profiles') IS NULL AND to_regclass('public.meinvoice_job_snapshot_versions') IS NULL AND NOT EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND ((table_name='direct_order_sessions' AND column_name='collection_bank_snapshot') OR (table_name='meinvoice_jobs' AND column_name='snapshot_version')))")" == "t" ]]
  printf 'CORPORATE_ATOMIC_ROLLBACK_TEST=PASS\n'
  run_sql < scripts/releases/20261011204000_corporate_sales_invoice_contacts_release.sql
else
  run_sql < supabase/migrations/20261011200000_corporate_collection_accounts.sql
  run_sql < supabase/migrations/20261011201000_invoice_ledger_export_contract.sql
  run_sql < supabase/migrations/20261011202000_sales_reporting_pages.sql
  run_sql < supabase/migrations/20261011203000_invoice_contacts_payment_methods.sql
fi
run_sql < test/sql/corporate_sales_export_test.sql
python3 - <<'PY' | run_sql
import json
from pathlib import Path
methods=json.loads(Path('test/fixtures/invoice_payment_contract.json').read_text())['methods']
print('CREATE TABLE fixture_invoice_payment_expectations(method text PRIMARY KEY,kind text,label text);')
for method,fields in methods.items():
    values=[method,fields['code'],fields['label']]
    print('INSERT INTO fixture_invoice_payment_expectations VALUES('+','.join("'"+v.replace("'","''")+"'" for v in values)+');')
PY
run_sql < test/sql/invoice_contacts_payment_methods_test.sql
run_sql <<'SQL' >/dev/null
ALTER TABLE public.meinvoice_jobs ADD COLUMN IF NOT EXISTS source_snapshot jsonb DEFAULT '{}';
SQL
run_sql < supabase/migrations/20261012010000_sales_invoice_mapping_contract.sql
run_sql < supabase/migrations/20261012020000_sales_export_page_contract.sql
run_sql < test/sql/sales_invoice_mapping_contract_test.sql
run_sql < test/sql/sales_export_scale_test.sql
# Rehearse the exact initial mapping payload against synthetic store/menu rows.
python3 - <<'PYINITIAL' | run_sql >/dev/null
import json
from pathlib import Path
payload=json.loads(Path('docs/pos/invoice_mapping_initial_20261011.json').read_text())
print("CREATE TABLE public.users(auth_id uuid,role text,is_active boolean);")
print("INSERT INTO public.users VALUES('00000000-0000-0000-0000-000000000001','super_admin',true);")
print("INSERT INTO public.restaurants(id,name,tax_entity_id) VALUES('80000000-0000-0000-0000-000000000001','BunsikClub Binh Thanh','"+payload['tax_entity_id']+"');")
for r in payload['rows']:
    if r['approval_type']=='menu_item':
        print("INSERT INTO public.menu_items(id,restaurant_id,name,vat_rate) VALUES('"+r['menu_item_id']+"','80000000-0000-0000-0000-000000000001','Synthetic initial menu',8);")
PYINITIAL
run_sql < supabase/migrations/20261012030000_sales_invoice_initial_mapping.sql
run_sql < supabase/migrations/20261012030000_sales_invoice_initial_mapping.sql
run_sql <<'SQL'
SELECT fixture_assert((SELECT count(*)=74 FROM invoice_approved_profiles WHERE mapping_version='AKJ-MANUAL-20261011-v1'),'initial one-day data migration is idempotent with exactly 74 approvals');
SQL
run_deposit_tests() {
  run_sql < test/sql/deposit_breakdown_setup.sql
  run_sql < supabase/migrations/20261012210000_deposit_breakdown.sql
  run_sql < supabase/migrations/20261012210000_deposit_breakdown.sql
  run_sql < test/sql/deposit_breakdown_test.sql
  if [[ -n "${GLOBOS_DEPOSIT_PERF_OUTPUT:-}" ]]; then
    python3 scripts/tests/deposit_breakdown_performance.py "$db_name" "$GLOBOS_DEPOSIT_PERF_OUTPUT"
  fi
}
# Both supported histories: timestamp order and the already deployed fee fix.
if [[ "${CORPORATE_RELEASE_ATOMIC:-0}" != 1 ]]; then run_deposit_tests; fi
python3 - "$ledger_tmp/delivery_fee_helper.sql" <<'PYFEE'
from pathlib import Path
import sys
s=Path('supabase/migrations/20261012230000_direct_order_no_delivery_fee.sql').read_text()
start=s.index('CREATE FUNCTION public.pos_is_delivery_fee_item(')
end=s.index('$$;',start)+3
Path(sys.argv[1]).write_text(s[start:end]+'\n')
PYFEE
run_sql < "$ledger_tmp/delivery_fee_helper.sql"
run_sql < test/sql/sales_export_no_delivery_fee_setup.sql
run_sql < supabase/migrations/20261012231000_sales_export_no_delivery_fee.sql
run_sql < test/sql/sales_export_no_delivery_fee_test.sql
if [[ "${CORPORATE_RELEASE_ATOMIC:-0}" == 1 ]]; then run_deposit_tests; fi
printf 'CORPORATE_SALES_SQL_TEST=PASS\n'
