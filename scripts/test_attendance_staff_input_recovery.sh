#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
run_name="pos-attendance-recovery-$$"
fixture_dir="$(mktemp -d)"
cleanup() { docker rm -f "$run_name" >/dev/null 2>&1 || true; rm -rf "$fixture_dir"; }
trap cleanup EXIT
docker run --detach --rm --name "$run_name" --env POSTGRES_HOST_AUTH_METHOD=trust --env POSTGRES_DB=payroll_test postgres:17.6 >/dev/null
for ((attempt=0;attempt<60;attempt++)); do
 if docker exec "$run_name" pg_isready -h 127.0.0.1 -U postgres -d payroll_test >/dev/null 2>&1; then break; fi
 sleep 1
done
run_sql() { docker exec -i "$run_name" psql -X -U postgres -d payroll_test -v ON_ERROR_STOP=1 < "$1"; }
run_sql scripts/fixtures/payroll_attendance.sql >/dev/null
run_sql scripts/fixtures/financial_inputs.sql >/dev/null
run_sql supabase/migrations/20260905020000_complete_financial_inputs.sql >/dev/null
python3 test/fixtures/attendance_staff_input_setup.py "$ROOT_DIR" > "$fixture_dir/setup.sql"
run_sql "$fixture_dir/setup.sql" >/dev/null
run_sql test/sql/attendance_staff_input_before.sql
python3 -B scripts/cloud_deployment/fixture_sql.py supabase/migrations/20261029084212_attendance_staff_input_recovery.sql > "$fixture_dir/cloud-migration.sql"
run_sql "$fixture_dir/cloud-migration.sql"
run_sql test/sql/attendance_staff_input_after.sql
printf 'ATTENDANCE_STAFF_INPUT_RECOVERY=PASS postgres=17 fixture_stores=7\n'
