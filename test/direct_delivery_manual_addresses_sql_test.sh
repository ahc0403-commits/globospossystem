#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
container="pos-manual-address-test-$$"
cleanup() { docker rm -f "$container" >/dev/null 2>&1 || true; }
trap cleanup EXIT
# Owned disposable database only, with no host ports or production credentials.
docker run --detach --rm --name "$container" \
  --env POSTGRES_PASSWORD=address-fixture --env POSTGRES_DB=codex_direct_manual \
  public.ecr.aws/supabase/postgres:17.6.1.104 >/dev/null
for attempt in $(seq 1 60); do
  if docker exec "$container" pg_isready -h 127.0.0.1 -U postgres -d codex_direct_manual >/dev/null 2>&1; then break; fi
  if [[ "$attempt" == 60 ]]; then exit 1; fi
  sleep 1
done
docker exec --env PGPASSWORD=address-fixture "$container" psql -X -v ON_ERROR_STOP=1 -U supabase_admin -d codex_direct_manual \
  -c 'ALTER DATABASE codex_direct_manual OWNER TO postgres' \
  -c 'CREATE TABLE IF NOT EXISTS auth.users(id uuid PRIMARY KEY); GRANT USAGE ON SCHEMA auth TO postgres; GRANT REFERENCES, INSERT ON auth.users TO postgres;' >/dev/null
run_sql() { docker exec -i "$container" psql -X -v ON_ERROR_STOP=1 -U postgres -d codex_direct_manual "$@"; }
# Use the actual predecessor table definitions and RPC, with only unrelated
# restaurant/menu dependencies reduced to the columns this RPC reads.
node <<'NODE' | run_sql >/dev/null
const fs = require('node:fs');
const source = fs.readFileSync('supabase/migrations/20260821130000_direct_delivery_ordering.sql', 'utf8');
console.log(`
CREATE TABLE public.restaurants(id uuid PRIMARY KEY);
CREATE TABLE public.menu_items(id uuid PRIMARY KEY, restaurant_id uuid, name text,
 name_ko text, name_vi text, name_en text, vat_category text, price numeric,
 is_available boolean, is_visible_public boolean, combo_drink_choice_count integer);
CREATE TABLE public.direct_order_storefronts(restaurant_id uuid PRIMARY KEY,
 is_enabled boolean, is_paused boolean, ordering_starts_at time, ordering_cutoff_at time,
 ordering_hours_enforced boolean NOT NULL DEFAULT true);
`);
for (const name of ['direct_order_sessions', 'direct_order_requests', 'direct_order_request_items',
  'direct_order_request_addresses', 'direct_order_location_facts', 'direct_order_messages']) {
  const start = source.indexOf('CREATE TABLE public.' + name + ' (');
  const end = source.indexOf('\n);', start);
  if (start < 0 || end < 0) throw new Error('Missing fixture table: ' + name);
  console.log(source.slice(start, end + 4));
}
console.log('ALTER TABLE public.direct_order_request_addresses ENABLE ROW LEVEL SECURITY;');
const start = source.indexOf('CREATE OR REPLACE FUNCTION public.direct_order_validate_session(');
const end = source.indexOf('CREATE OR REPLACE FUNCTION public.direct_order_public_message(', start);
const hours = fs.readFileSync('supabase/migrations/20260824013000_direct_delivery_pilot_open_hours.sql', 'utf8');
const oldHours = hours.match(/v_old_submit constant text := \$old\$([\s\S]*?)\$old\$/)[1];
const newHours = hours.match(/v_new_submit constant text := \$new\$([\s\S]*?)\$new\$/)[1];
console.log(source.slice(start, end).replace(oldHours, () => newHours));
NODE
run_sql < scripts/preflight_direct_delivery_manual_addresses.sql >/dev/null
run_sql < supabase/migrations/20260907130000_direct_delivery_manual_addresses.sql >/dev/null
run_sql < scripts/verify_direct_delivery_manual_addresses.sql >/dev/null
run_sql < test/sql/direct_delivery_manual_addresses_test.sql >/dev/null
run_sql < test/sql/direct_delivery_cash_payout_setup.sql >/dev/null
node <<'NODE' | run_sql >/dev/null
const fs = require('node:fs');
const source = fs.readFileSync('supabase/migrations/20260821130000_direct_delivery_ordering.sql', 'utf8');
const start = source.indexOf('CREATE TABLE public.direct_order_dispatches (');
console.log(source.slice(start, source.indexOf('\n);', start) + 4));
for (const [file,names] of [
  ['20260824060000_direct_delivery_kds_routing.sql',['direct_order_set_dispatch']],
  ['20260809100000_daily_closing_by_business_date.sql',['get_daily_closing_cash_preview','create_daily_closing']],
  ['20260809110000_daily_closing_payment_methods.sql',['get_daily_closing_days']],
]) {
  const sql=fs.readFileSync('supabase/migrations/'+file,'utf8');
  for(const name of names) {
    const match=new RegExp('CREATE (?:OR REPLACE )?FUNCTION public\\.'+name+'\\(').exec(sql);
    const end=sql.indexOf('$$;',match.index)+3;
    console.log(sql.slice(match.index,end));
  }
}
console.log(`REVOKE ALL ON FUNCTION public.direct_order_set_dispatch(uuid,uuid,text,numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.direct_order_set_dispatch(uuid,uuid,text,numeric) TO authenticated, service_role;`);
NODE
run_sql < scripts/preflight_direct_delivery_cash_payout_daily_closing.sql >/dev/null
run_sql < supabase/migrations/20260907100000_direct_delivery_cash_payout_daily_closing.sql >/dev/null
run_sql < scripts/verify_direct_delivery_cash_payout_daily_closing.sql >/dev/null
run_sql < test/sql/direct_delivery_cash_payout_test.sql >/dev/null
printf 'DIRECT_DELIVERY_MANUAL_ADDRESSES_SQL_TEST=PASS\n'
printf 'DIRECT_DELIVERY_CASH_PAYOUT_SQL_TEST=PASS\n'
