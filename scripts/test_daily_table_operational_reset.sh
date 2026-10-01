#!/usr/bin/env bash
set -euo pipefail
if ! command -v initdb >/dev/null 2>&1 && command -v pg_config >/dev/null 2>&1; then
  export PATH="$(pg_config --bindir):$PATH"
fi
RESET_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESET_TMP="$(mktemp -d "${TMPDIR:-/tmp}/daily-table-reset.XXXXXX")"
RESET_CONTAINER=""
RESET_PORT="$(python3 - <<'PY'
import socket
with socket.socket() as s:
    s.bind(('127.0.0.1',0));print(s.getsockname()[1])
PY
)"
cleanup() {
  if [[ -n "$RESET_CONTAINER" ]]; then
    docker rm -f "$RESET_CONTAINER" >/dev/null 2>&1 || true
  else
    pg_ctl -D "$RESET_TMP/data" -m immediate stop >/dev/null 2>&1 || true
  fi
  rm -rf "$RESET_TMP"
}
trap cleanup EXIT
if command -v initdb >/dev/null 2>&1 && command -v pg_ctl >/dev/null 2>&1; then
  initdb -D "$RESET_TMP/data" --username=postgres --auth=trust --encoding=UTF8 --locale=C >/dev/null
  pg_ctl -D "$RESET_TMP/data" -l "$RESET_TMP/server.log" -o "-h 127.0.0.1 -p $RESET_PORT -k $RESET_TMP" -w start >/dev/null
else
  RESET_CONTAINER="pos-daily-table-reset-$$"
  docker run --detach --rm --name "$RESET_CONTAINER" \
    --env POSTGRES_HOST_AUTH_METHOD=trust --publish "127.0.0.1:$RESET_PORT:5432" postgres:15 >/dev/null
  for attempt in $(seq 1 30); do
    if pg_isready -h 127.0.0.1 -p "$RESET_PORT" -U postgres >/dev/null 2>&1; then break; fi
    if [[ "$attempt" == 30 ]]; then exit 1; fi
    sleep 1
  done
fi
python3 "$RESET_ROOT/scripts/tests/daily_table_reset_fixture.py" "$RESET_ROOT" "$RESET_TMP/fixture.sql"
run_sql() { psql -X -h 127.0.0.1 -p "$RESET_PORT" -U postgres -d "${2:-postgres}" -v ON_ERROR_STOP=1 -f "$1"; }
run_sql "$RESET_TMP/fixture.sql" >/dev/null
run_sql "$RESET_ROOT/scripts/preflight_daily_table_operational_reset.sql"
psql -X -h 127.0.0.1 -p "$RESET_PORT" -U postgres -d postgres -v ON_ERROR_STOP=1 --single-transaction \
  -f "$RESET_ROOT/supabase/migrations/20261001020000_daily_table_operational_reset.sql" >/dev/null
run_sql "$RESET_ROOT/scripts/verify_daily_table_operational_reset.sql"
if ! run_sql "$RESET_ROOT/supabase/tests/daily_table_operational_reset_test.sql" >"$RESET_TMP/behavior.log" 2>&1; then
  tail -50 "$RESET_TMP/behavior.log"
  exit 1
fi
python3 "$RESET_ROOT/scripts/tests/daily_table_reset_concurrency.py" "$RESET_PORT"
run_sql "$RESET_ROOT/scripts/rollback_daily_table_operational_reset.sql"
psql -X -h 127.0.0.1 -p "$RESET_PORT" -U postgres -d postgres -v ON_ERROR_STOP=1 -c "SELECT test_assert((SELECT count(*)=6 FROM order_operational_closures WHERE order_id IN (test_uuid(1001),test_uuid(2001),test_uuid(2002),test_uuid(2003),test_uuid(2004),test_uuid(2011))), 'rollback retains original closure history');" >/dev/null
printf 'DAILY_TABLE_OPERATIONAL_RESET_SQL_TEST=PASS\n'

# Verify the actual production apply wrapper and its atomic incident safeguard.
for reset_apply_case in success changed_payment legacy_without_mutation_rpc; do
  reset_apply_db="daily_reset_apply_$reset_apply_case"
  createdb -h 127.0.0.1 -p "$RESET_PORT" -U postgres "$reset_apply_db"
  run_sql "$RESET_TMP/fixture.sql" "$reset_apply_db" >/dev/null
  psql -X -h 127.0.0.1 -p "$RESET_PORT" -U postgres -d "$reset_apply_db" -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
INSERT INTO orders(id,restaurant_id,table_id,status,created_at)
SELECT 'a797c8d3-0315-4f91-8a71-66c40c8db945',restaurant_id,table_id,status,created_at FROM orders WHERE id=test_uuid(1001);
INSERT INTO order_items(order_id,restaurant_id,menu_item_id,status)
VALUES('a797c8d3-0315-4f91-8a71-66c40c8db945',test_uuid(1),test_uuid(10),'ready');
SQL
  if [[ "$reset_apply_case" == "legacy_without_mutation_rpc" ]]; then
    psql -X -h 127.0.0.1 -p "$RESET_PORT" -U postgres -d "$reset_apply_db" -v ON_ERROR_STOP=1 \
      -c "DROP FUNCTION create_order_with_client_mutation_id(uuid,uuid,jsonb,text); DROP TABLE pos_client_mutation_attempts;" >/dev/null
  fi
  run_sql "$RESET_ROOT/scripts/preflight_daily_table_operational_reset.sql" "$reset_apply_db" >/dev/null
  if [[ "$reset_apply_case" == "changed_payment" ]]; then
    psql -X -h 127.0.0.1 -p "$RESET_PORT" -U postgres -d "$reset_apply_db" -v ON_ERROR_STOP=1 \
      -c "INSERT INTO payments(order_id,restaurant_id,amount) VALUES('a797c8d3-0315-4f91-8a71-66c40c8db945',test_uuid(1),40);" >/dev/null
    if run_sql "$RESET_ROOT/scripts/apply_daily_table_operational_reset.sql" "$reset_apply_db" >"$RESET_TMP/apply-failed.log" 2>&1; then exit 1; fi
    grep -q 'INCIDENT_PAYMENT_CHANGED_REVIEW_REQUIRED' "$RESET_TMP/apply-failed.log"
    psql -X -h 127.0.0.1 -p "$RESET_PORT" -U postgres -d "$reset_apply_db" -v ON_ERROR_STOP=1 \
      -c "SELECT test_assert(to_regclass('public.order_operational_closures') IS NULL,'failed recovery rolls back schema and policy');" >/dev/null
  else
    run_sql "$RESET_ROOT/scripts/apply_daily_table_operational_reset.sql" "$reset_apply_db" >/dev/null
    run_sql "$RESET_ROOT/scripts/verify_daily_table_operational_reset.sql" "$reset_apply_db" >/dev/null
    psql -X -h 127.0.0.1 -p "$RESET_PORT" -U postgres -d "$reset_apply_db" -v ON_ERROR_STOP=1 \
      -c "SELECT test_assert((SELECT status='available' FROM tables WHERE id=test_uuid(101)),'guarded apply releases incident'); SELECT test_assert((SELECT count(*)=1 FROM audit_logs WHERE action='recover_stale_1222'),'guarded apply records incident reason');" >/dev/null
    if [[ "$reset_apply_case" == "legacy_without_mutation_rpc" ]]; then
      psql -X -h 127.0.0.1 -p "$RESET_PORT" -U postgres -d "$reset_apply_db" -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
BEGIN;
SET LOCAL request.jwt.claim.sub='91000000-0000-4000-8000-000000000004';
SET LOCAL request.jwt.claim.role='authenticated';
SELECT test_assert((create_order_for_business_day(test_uuid(1),test_uuid(101),
 '[{"menu_item_id":"91000000-0000-4000-8000-000000000011","quantity":1}]',
 'legacy-today',(now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date)).id IS NOT NULL,
 'today creation works without optional mutation RPC or ledger');
DO $$ BEGIN
 BEGIN PERFORM create_order_for_business_day(test_uuid(1),test_uuid(102),'[]','legacy-expired',
  (now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date-1);
 RAISE EXCEPTION 'OLD_OFFLINE_ACCEPTED'; EXCEPTION WHEN OTHERS THEN
  PERFORM test_assert(SQLERRM='ORDER_BUSINESS_DAY_EXPIRED','legacy path rejects expired offline creation'); END;
 BEGIN PERFORM create_order_for_business_day(test_uuid(1),test_uuid(102),'[]','',
  (now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date);
 RAISE EXCEPTION 'EMPTY_MUTATION_ACCEPTED'; EXCEPTION WHEN OTHERS THEN
  PERFORM test_assert(SQLERRM='CLIENT_MUTATION_ID_REQUIRED','legacy path requires mutation identity'); END;
END $$;
ROLLBACK;
SQL
      printf 'DAILY_TABLE_OPERATIONAL_RESET_LEGACY_COMPAT=PASS\n'
    fi
  fi
done
printf 'DAILY_TABLE_OPERATIONAL_RESET_GUARDED_APPLY=PASS\n'
