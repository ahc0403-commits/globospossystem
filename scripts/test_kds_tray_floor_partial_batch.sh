#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

fixture_name="pos-kds-tray-partial-$$"
cleanup() {
  docker rm -f "$fixture_name" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker run --detach --rm --name "$fixture_name" \
  --env POSTGRES_PASSWORD=kds-tray-partial-fixture \
  --env POSTGRES_DB=kds_tray_partial_fixture \
  postgres:15 >/dev/null

for attempt in $(seq 1 60); do
  if docker exec "$fixture_name" \
    psql -X -v ON_ERROR_STOP=1 -U postgres -d kds_tray_partial_fixture \
      -c 'SELECT 1' >/dev/null 2>&1; then
    break
  fi
  if [[ "$attempt" == 60 ]]; then
    exit 1
  fi
  sleep 1
done

run_sql() {
  docker exec -i "$fixture_name" \
    psql -X -v ON_ERROR_STOP=1 -U postgres -d kds_tray_partial_fixture
}

run_sql < test/fixtures/kds_tray_floor_partial_batch_setup.sql >/dev/null
run_sql < scripts/preflight_kds_tray_floor_partial_batch.sql >/dev/null
run_sql < supabase/migrations/20260919010000_kds_tray_floor_partial_batch.sql \
  >/dev/null
run_sql < scripts/verify_kds_tray_floor_partial_batch.sql >/dev/null
run_sql < supabase/tests/kds_tray_floor_partial_batch_test.sql >/dev/null
run_sql < scripts/rollback_kds_tray_floor_partial_batch.sql >/dev/null
run_sql < scripts/preflight_kds_tray_floor_partial_batch.sql >/dev/null
run_sql < supabase/migrations/20260919010000_kds_tray_floor_partial_batch.sql \
  >/dev/null
run_sql < scripts/verify_kds_tray_floor_partial_batch.sql >/dev/null
run_sql < supabase/tests/kds_tray_floor_partial_batch_test.sql >/dev/null

printf 'KDS_TRAY_FLOOR_PARTIAL_BATCH_SQL_TEST=PASS\n'
