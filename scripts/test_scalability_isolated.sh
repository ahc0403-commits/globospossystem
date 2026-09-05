#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
run_name="pos-scale-test-$$"
db_name="${run_name}-db"
rest_name="${run_name}-rest"
output_dir="${1:-/tmp/pos-scalability-measurements}"
mkdir -p "$output_dir"
cleanup() {
  docker rm -f "$rest_name" "$db_name" >/dev/null 2>&1 || true
  docker network rm "$run_name" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker network create "$run_name" >/dev/null
docker run --detach --rm --name "$db_name" --network "$run_name" --cpus=2 --memory=2g \
  --env POSTGRES_PASSWORD=scale-fixture --env POSTGRES_DB=payroll_test \
  public.ecr.aws/supabase/postgres:17.6.1.104 \
  postgres -D /etc/postgresql -c shared_preload_libraries=pg_stat_statements \
  -c pg_stat_statements.track=all >/dev/null
for attempt in $(seq 1 60); do
  if docker exec "$db_name" pg_isready -h 127.0.0.1 -U postgres -d payroll_test >/dev/null 2>&1; then break; fi
  if [[ "$attempt" == 60 ]]; then docker logs --tail 40 "$db_name"; exit 1; fi
  sleep 1
done
docker exec --env PGPASSWORD=scale-fixture "$db_name" psql -X -v ON_ERROR_STOP=1 -U supabase_admin -d payroll_test \
  -c 'ALTER DATABASE payroll_test OWNER TO postgres; CREATE EXTENSION IF NOT EXISTS pg_stat_statements' >/dev/null
docker exec -i --env PGPASSWORD=scale-fixture "$db_name" psql -X -v ON_ERROR_STOP=1 -U supabase_admin -d payroll_test \
  < scripts/fixtures/payroll_attendance.sql >/dev/null
for sql_file in scripts/fixtures/financial_inputs.sql scripts/fixtures/scalability.sql \
  supabase/migrations/20260905040000_store_revenue_summary.sql \
  supabase/migrations/20260905060000_store_report_summary.sql; do
  docker exec -i "$db_name" psql -X -v ON_ERROR_STOP=1 -U postgres -d payroll_test < "$sql_file" >/dev/null
done
docker run --detach --rm --name "$rest_name" --network "$run_name" --cpus=1 --memory=512m \
  --publish 127.0.0.1::3000 --env "PGRST_DB_URI=postgres://postgres@${db_name}:5432/payroll_test" \
  --env PGPASSWORD=scale-fixture --env PGRST_DB_ANON_ROLE=authenticated --env PGRST_DB_SCHEMAS=public \
  --env PGRST_DB_POOL=10 --env PGRST_DB_POOL_ACQUISITION_TIMEOUT=10 --env PGRST_DB_MAX_ROWS=100 \
  public.ecr.aws/supabase/postgrest:v14.5 >/dev/null
rest_address="$(docker port "$rest_name" 3000/tcp)"
for attempt in $(seq 1 60); do
  if curl --fail --silent "http://${rest_address}/" >/dev/null; then break; fi
  if [[ "$attempt" == 60 ]]; then docker logs --tail 40 "$rest_name"; exit 1; fi
  sleep 1
done
SCALE_DB_CONTAINER="$db_name" SCALE_REST_CONTAINER="$rest_name" SCALE_RPC_URL="http://${rest_address}" \
  node scripts/measure_scalability.mjs "$output_dir"
