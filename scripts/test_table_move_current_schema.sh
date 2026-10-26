#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
balance_schema="${1:?Pass an approved schema-only public,pos_invoice_private export}"
[[ -f "$balance_schema" ]] || exit 2
balance_fixture="pos-table-balance-upgrade-$$"
balance_tmp="$(mktemp -d)"
cleanup() { docker rm -f "$balance_fixture" >/dev/null 2>&1 || true; rm -rf "$balance_tmp"; }
trap cleanup EXIT
python3 - "$balance_schema" "$balance_tmp" <<'PY'
from pathlib import Path
import sys
source=Path(sys.argv[1]).read_text();out=Path(sys.argv[2])
assert '-- Data for Name:' not in source, 'Schema-only export required'
(out/'schema.sql').write_text(source.replace('CREATE SCHEMA public;','CREATE SCHEMA IF NOT EXISTS public;').replace('CREATE SCHEMA pos_invoice_private;','CREATE SCHEMA IF NOT EXISTS pos_invoice_private;'))
previous=''
for before,after in [('qr_get_active_order_pre_takeout','fixture_qr_base_before'),('emergency_enrich_qr_unserved_items','fixture_qr_enrich_before')]:
 start=source.index('CREATE FUNCTION public.'+before+'(');end=source.index('\n\n--',start)
 previous+=source[start:end].replace('public.'+before+'(', 'public.'+after+'(',1)+'\n'
(out/'previous.sql').write_text(previous)
s=Path('test/sql/store_workflow_move_fifo_test.sql').read_text()
s=s.replace('r:=public.cashier_move_order_items',"EXECUTE 'LOAD ''safeupdate''';\n r:=public.cashier_move_order_items",1)
(out/'fifo.sql').write_text(s)
PY
docker run -d --rm --network none --name "$balance_fixture" --env POSTGRES_PASSWORD=fixture-only public.ecr.aws/supabase/postgres:17.6.1.104 >/dev/null
for attempt in {1..60}; do
 if docker exec "$balance_fixture" pg_isready -h 127.0.0.1 -U supabase_admin -d postgres >/dev/null 2>&1; then break; fi
 [[ "$attempt" != 60 ]] || exit 1
 sleep 1
done
run_sql() { docker exec -i --env PGPASSWORD=fixture-only "$balance_fixture" psql -X -U supabase_admin -d postgres -v ON_ERROR_STOP=1; }
run_sql <<'SQL' >/dev/null
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public REVOKE ALL ON FUNCTIONS FROM anon,authenticated,service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON FUNCTIONS FROM anon,authenticated,service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE supabase_admin IN SCHEMA public REVOKE ALL ON TABLES FROM anon,authenticated,service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON TABLES FROM anon,authenticated,service_role;
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;
SQL
run_sql < "$balance_tmp/schema.sql" > "$balance_tmp/restore.log" 2>&1 || { tail -n 15 "$balance_tmp/restore.log"; exit 1; }
run_sql < test/fixtures/store_operating_upgrade_setup.sql >/dev/null
# Only synthetic stores in this disconnected container are activated.
run_sql <<'SQL' >/dev/null
UPDATE public.store_lifecycle SET state='active' WHERE restaurant_id IN ('273b057e-3b69-46e3-93c1-6194c2802849','8bc9eef5-dcd5-46b1-b931-23f77132322c');
SQL
run_sql < "$balance_tmp/previous.sql" >/dev/null
run_sql < scripts/preflight_table_move_and_qr_payment_summary.sql
run_sql < supabase/migrations/20261024110000_table_move_and_qr_payment_summary.sql
run_sql < scripts/verify_table_move_and_qr_payment_summary.sql
run_sql < "$balance_tmp/fifo.sql"
run_sql < supabase/tests/table_move_qr_current_schema_test.sql
printf 'TABLE_BALANCE_CURRENT_SCHEMA=PASS network=none\n'
