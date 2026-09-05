#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# Own disposable DB only: no production credentials, ports, or existing DBs.
db_name="pos-promotion-test-$$"
cleanup() { docker rm -f "$db_name" >/dev/null 2>&1 || true; }
trap cleanup EXIT
docker run --detach --rm --name "$db_name" \
  --env POSTGRES_PASSWORD=promotion-fixture --env POSTGRES_DB=promotion_test \
  public.ecr.aws/supabase/postgres:17.6.1.104 \
  postgres -D /etc/postgresql -c shared_preload_libraries=pg_cron \
  -c cron.database_name=promotion_test -c cron.launch_active_jobs=off >/dev/null
for attempt in $(seq 1 60); do
  if docker exec "$db_name" pg_isready -h 127.0.0.1 -U postgres -d promotion_test >/dev/null 2>&1; then break; fi
  if [[ "$attempt" == 60 ]]; then docker logs --tail 60 "$db_name"; exit 1; fi
  sleep 1
done
docker exec --env PGPASSWORD=promotion-fixture "$db_name" psql -X -v ON_ERROR_STOP=1 -U supabase_admin -d promotion_test \
  -c 'ALTER DATABASE promotion_test OWNER TO postgres' >/dev/null
docker exec -i --env PGPASSWORD=promotion-fixture "$db_name" psql -X -v ON_ERROR_STOP=1 -U supabase_admin -d promotion_test \
  < scripts/fixtures/promotion_sync.sql >/dev/null
run_sql() {
  docker exec -i "$db_name" psql -X -v ON_ERROR_STOP=1 -U postgres -d promotion_test "$@"
}
# Load actual historical table DDL and entry points, without the unrelated
# settlement/cron migrations. Function bodies are not duplicated in fixtures.
sed -n '/^CREATE TABLE IF NOT EXISTS public.order_discounts (/,/^GRANT ALL ON public.order_discounts TO service_role;/p' \
  supabase/migrations/20260706010000_discount_staff_meal_v1_schema.sql | run_sql >/dev/null
sed -n '/^CREATE TABLE IF NOT EXISTS public.store_promotions (/,/^GRANT ALL ON public.store_promotions TO service_role;/p' \
  supabase/migrations/20260804010000_scheduled_closing_and_promotions.sql | run_sql >/dev/null
for function_name in refresh_store_order_promotions trg_sync_order_promotion void_active_order_discount_for_item_change; do
  sed -n "/^CREATE OR REPLACE FUNCTION public.${function_name}(/,/^\$\$;/p" \
    supabase/migrations/20260804010000_scheduled_closing_and_promotions.sql | run_sql >/dev/null
done
run_sql < supabase/migrations/20260817110000_menu_scoped_promotion_integrity.sql >/dev/null
# Same grants as the original refresh migration.
run_sql -c "REVOKE ALL ON FUNCTION public.refresh_store_order_promotions(uuid,timestamptz) FROM PUBLIC, anon; GRANT EXECUTE ON FUNCTION public.refresh_store_order_promotions(uuid,timestamptz) TO authenticated, service_role;" >/dev/null
run_sql -c "CREATE TABLE fixture_payment_contract AS SELECT pg_get_functiondef('public.process_payment(uuid,uuid,numeric,text)'::regprocedure) AS definition" >/dev/null
sed -n '/^CREATE OR REPLACE FUNCTION public.sync_active_order_promotion(/,/^\$\$;/p' \
  supabase/migrations/20260817110000_menu_scoped_promotion_integrity.sql \
  | sed 's/FUNCTION public.sync_active_order_promotion(/FUNCTION public.fixture_original_sync(/' \
  | run_sql >/dev/null
if [[ "${PROMOTION_TEST_BASELINE:-0}" != 1 ]]; then
  for sql_file in scripts/preflight_idempotent_promotion_sync.sql \
    supabase/migrations/20260905030000_idempotent_promotion_sync.sql \
    scripts/verify_idempotent_promotion_sync.sql; do
    run_sql < "$sql_file" >/dev/null
  done
fi
run_sql < test/sql/promotion_sync_test.sql >/dev/null

if [[ "${PROMOTION_TEST_BASELINE:-0}" != 1 ]]; then
  run_sql < supabase/migrations/20260905030000_idempotent_promotion_sync.sql >/dev/null
  run_sql < scripts/verify_idempotent_promotion_sync.sql >/dev/null
  run_sql -c "SELECT fixture_assert((SELECT count(*) = 0 FROM fixture_writes), 'migration reapplication does not modify business rows')" >/dev/null
fi
if [[ "${PROMOTION_TEST_BASELINE:-0}" != 1 ]]; then
  docker exec --env PGPASSWORD=promotion-fixture "$db_name" psql -X -v ON_ERROR_STOP=1 -U supabase_admin -d promotion_test \
    -c 'CREATE EXTENSION pg_cron; GRANT USAGE ON SCHEMA cron TO postgres;' >/dev/null
  run_sql -c "ALTER TABLE orders ADD COLUMN created_at timestamptz NOT NULL DEFAULT now(); CREATE TABLE pos_live_events(id bigserial,restaurant_id uuid,domain text,source_table text,event_type text);" >/dev/null
  sed -n '/^CREATE OR REPLACE FUNCTION public.emit_pos_live_event()/,/^\$\$;/p' \
    supabase/migrations/20260805090000_pos_live_events_all_domains.sql | run_sql >/dev/null
  run_sql -c "CREATE TRIGGER pos_live_event_trigger AFTER INSERT OR UPDATE OR DELETE ON order_discounts FOR EACH ROW EXECUTE FUNCTION emit_pos_live_event('orders');" >/dev/null
  for sql_file in scripts/preflight_promotion_read_write_separation.sql \
    supabase/migrations/20260905070000_promotion_read_write_separation.sql \
    scripts/verify_promotion_read_write_separation.sql \
    scripts/preflight_promotion_allocation_live_refresh.sql \
    supabase/migrations/20260905090000_promotion_allocation_live_refresh.sql \
    scripts/verify_promotion_allocation_live_refresh.sql \
    test/sql/promotion_read_write_separation_test.sql \
    supabase/migrations/20260905070000_promotion_read_write_separation.sql \
    scripts/verify_promotion_read_write_separation.sql; do
    run_sql < "$sql_file" >/dev/null
  done
  run_sql < test/sql/promotion_line_event_regression_test.sql >/dev/null
  run_sql < supabase/migrations/20260905090000_promotion_allocation_live_refresh.sql >/dev/null
  run_sql < scripts/preflight_promotion_allocation_live_refresh.sql >/dev/null
  run_sql < scripts/verify_promotion_allocation_live_refresh.sql >/dev/null
  run_sql -c "SELECT fixture_assert((SELECT count(*)=0 FROM fixture_writes) AND (SELECT count(*)=0 FROM pos_live_events), 'allocation migration replay does not modify business rows or emit events')" >/dev/null
  run_sql < test/sql/promotion_line_event_regression_test.sql >/dev/null
fi
# Hold a real active-discount lock so a second refresh must wait, then check
# that neither transaction rewrites the unchanged discount after acquiring it.
run_sql -c "TRUNCATE fixture_writes" >/dev/null
run_sql -c "SET application_name = 'promotion-holder'; BEGIN; SELECT id FROM order_discounts WHERE status = 'active' FOR UPDATE; SELECT pg_sleep(5); SELECT sync_active_order_promotion('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001'); COMMIT;" >/dev/null &
first_pid=$!
wait_for_activity() {
  local predicate="$1"
  for attempt in $(seq 1 30); do
    if [[ "$(run_sql -Atc "SELECT count(*) FROM pg_stat_activity WHERE $predicate")" == 1 ]]; then return; fi
    sleep 0.1
  done
  printf 'Expected concurrent session state was not observed: %s\n' "$predicate" >&2
  return 1
}
wait_for_activity "application_name = 'promotion-holder' AND wait_event = 'PgSleep'"
run_sql -c "SET application_name = 'promotion-waiter'; SELECT sync_active_order_promotion('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001');" >/dev/null &
second_pid=$!
wait_for_activity "application_name = 'promotion-waiter' AND wait_event_type = 'Lock'"
wait "$first_pid"
wait "$second_pid"
run_sql -c "SELECT fixture_assert((SELECT count(*) = 0 FROM fixture_writes), 'concurrent unchanged syncs perform zero writes')" >/dev/null
printf 'PROMOTION_SQL_TEST=PASS\n'
