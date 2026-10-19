#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
setup_test_db="pos-printer-modes-$$"
trap 'docker rm -f "$setup_test_db" >/dev/null 2>&1 || true' EXIT
docker run --detach --rm --name "$setup_test_db" --env POSTGRES_PASSWORD=fixture-only --env POSTGRES_DB=printer_test public.ecr.aws/supabase/postgres:17.6.1.104 -c shared_preload_libraries=pg_stat_statements -c pg_stat_statements.track=all >/dev/null
for attempt in $(seq 1 60); do
  if docker exec "$setup_test_db" pg_isready -h 127.0.0.1 -U postgres -d printer_test >/dev/null 2>&1; then break; fi
  if [[ "$attempt" == 60 ]]; then exit 1; fi
  sleep 1
done
run_sql() { docker exec -i "$setup_test_db" psql -X -v ON_ERROR_STOP=1 -U postgres -d printer_test; }
docker exec --env PGPASSWORD=fixture-only "$setup_test_db" psql -X -v ON_ERROR_STOP=1 -U supabase_admin -d printer_test -c 'ALTER DATABASE printer_test OWNER TO postgres' >/dev/null
run_sql < test/fixtures/store_opening_printer_modes_setup.sql >/dev/null
python3 - <<'PY' | run_sql >/dev/null
from pathlib import Path
extracts = [
 ('20260717170000_workforce_fixed_accounts.sql','CREATE OR REPLACE FUNCTION public.require_admin_actor_for_restaurant(', 'INSERT INTO public.workforce_fixed_account_migration_state'),
 ('20260810160000_print_station_printer_configuration.sql','CREATE OR REPLACE FUNCTION public.require_printer_configuration_actor(', 'REVOKE ALL ON FUNCTION'),
 ('20260811170000_pos_paperless_receipts.sql','CREATE OR REPLACE FUNCTION public.get_store_fulfillment_mode(', 'CREATE OR REPLACE FUNCTION public.capture_order_fulfillment_mode('),
 ('20260812155000_floor_direct_beverage_settings.sql','CREATE OR REPLACE FUNCTION public.super_admin_set_fulfillment_mode(', 'CREATE OR REPLACE FUNCTION public.super_admin_get_fulfillment_store_statuses('),
]
for name,start,end in extracts:
 s=(Path('supabase/migrations')/name).read_text();a=s.index(start);b=s.index(end,a);print(s[a:b])
PY
run_sql < supabase/migrations/20260717090000_store_opening_setup_wizard.sql >/dev/null
run_sql < supabase/migrations/20260808220000_printer_network_endpoints.sql >/dev/null
run_sql < supabase/migrations/20260811160000_usb_printer_endpoints.sql >/dev/null
run_sql < supabase/migrations/20261019160000_store_opening_printer_modes.sql >/dev/null
run_sql < supabase/migrations/20261019160000_store_opening_printer_modes.sql >/dev/null
run_sql < test/sql/store_opening_printer_modes_test.sql
