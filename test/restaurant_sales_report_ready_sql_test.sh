#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
db_name="pos-report-ready-test-$$"
cleanup() { docker rm -f "$db_name" >/dev/null 2>&1 || true; }
trap cleanup EXIT
# Only an owned disposable database; no production credentials or host ports.
docker run --detach --rm --name "$db_name" \
  --env POSTGRES_PASSWORD=report-fixture --env POSTGRES_DB=report_ready_test \
  public.ecr.aws/supabase/postgres:17.6.1.104 >/dev/null
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
printf 'RESTAURANT_REPORT_READY_SQL_TEST=PASS\n'
