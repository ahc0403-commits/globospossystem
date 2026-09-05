#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# Entirely disposable containers; no production credentials or existing DBs.
run_name="pos-financial-test-$$"
db_name="${run_name}-db"
rest_name="${run_name}-rest"
cleanup() {
  docker rm -f "$rest_name" "$db_name" >/dev/null 2>&1 || true
  docker network rm "$run_name" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker network create "$run_name" >/dev/null
printf 'FINANCIAL_API_TEST_STEP=database_start\n'
docker run --detach --rm --name "$db_name" --network "$run_name" \
  --env POSTGRES_PASSWORD=payroll-fixture --env POSTGRES_DB=payroll_test \
  public.ecr.aws/supabase/postgres:17.6.1.104 >/dev/null
for attempt in $(seq 1 60); do
  # Bootstrap uses a Unix socket only; TCP readiness excludes that temporary DB.
  if docker exec "$db_name" pg_isready -h 127.0.0.1 -U postgres -d payroll_test >/dev/null 2>&1; then break; fi
  if [[ "$attempt" == 60 ]]; then docker logs --tail 60 "$db_name"; exit 1; fi
  sleep 1
done
# Supabase's image creates custom databases under supabase_admin; assign only
# this disposable fixture DB to the same migration role used by the project.
docker exec --env PGPASSWORD=payroll-fixture "$db_name" psql -X -v ON_ERROR_STOP=1 -U supabase_admin -d payroll_test \
  -c 'ALTER DATABASE payroll_test OWNER TO postgres' >/dev/null
docker exec -i --env PGPASSWORD=payroll-fixture "$db_name" psql -X -v ON_ERROR_STOP=1 -U supabase_admin -d payroll_test \
  < scripts/fixtures/payroll_attendance.sql >/dev/null
for sql_file in \
  scripts/fixtures/financial_inputs.sql \
  supabase/migrations/20260724025456_attendance_logs_with_names.sql \
  scripts/preflight_payroll_complete_attendance.sql \
  supabase/migrations/20260905010000_payroll_complete_attendance.sql \
  scripts/verify_payroll_complete_attendance.sql \
  scripts/preflight_complete_financial_inputs.sql \
  supabase/migrations/20260905020000_complete_financial_inputs.sql \
  scripts/verify_complete_financial_inputs.sql \
  scripts/preflight_store_revenue_summary.sql \
  supabase/migrations/20260905040000_store_revenue_summary.sql \
  scripts/verify_store_revenue_summary.sql \
  supabase/migrations/20260905040000_store_revenue_summary.sql \
  scripts/verify_store_revenue_summary.sql; do
  printf 'FINANCIAL_API_TEST_SQL=%s\n' "$sql_file"
  docker exec -i "$db_name" psql -X -v ON_ERROR_STOP=1 -U postgres -d payroll_test < "$sql_file" >/dev/null
done
printf 'FINANCIAL_API_TEST_STEP=postgrest_start\n'
docker run --detach --rm --name "$rest_name" --network "$run_name" \
  --publish 127.0.0.1::3000 \
  --env "PGRST_DB_URI=postgres://postgres@${db_name}:5432/payroll_test" \
  --env PGPASSWORD=payroll-fixture \
  --env PGRST_DB_ANON_ROLE=authenticated --env PGRST_DB_SCHEMAS=public \
  --env PGRST_DB_MAX_ROWS=100 \
  public.ecr.aws/supabase/postgrest:v14.5 >/dev/null
rest_address="$(docker port "$rest_name" 3000/tcp)"
for attempt in $(seq 1 60); do
  if curl --fail --silent "http://${rest_address}/" >/dev/null; then break; fi
  if [[ "$attempt" == 60 ]]; then docker logs --tail 60 "$rest_name"; exit 1; fi
  sleep 1
done
FINANCIAL_TEST_DB_CONTAINER="$db_name" FINANCIAL_TEST_RPC_URL="http://${rest_address}" \
  flutter test --no-pub test/financial_inputs_postgrest_test.dart
