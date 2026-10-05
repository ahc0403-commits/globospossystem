#!/usr/bin/env bash
set -euo pipefail
RETIREMENT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RETIREMENT_CONTAINER="globos-deliberry-retirement-$$"
RETIREMENT_TMP="$(mktemp -d)"
cleanup() {
  docker rm -f "$RETIREMENT_CONTAINER" >/dev/null 2>&1 || true
  rm -rf "$RETIREMENT_TMP"
}
trap cleanup EXIT
docker run --detach --rm --name "$RETIREMENT_CONTAINER" \
  --env POSTGRES_HOST_AUTH_METHOD=trust postgres:15 >/dev/null
retirement_ready=0
for retirement_attempt in $(seq 1 60); do
  if docker exec "$RETIREMENT_CONTAINER" pg_isready -U postgres >/dev/null 2>&1; then
    retirement_ready=1
    break
  fi
  sleep 0.2
done
if [[ "$retirement_ready" != 1 ]]; then
  echo 'Retirement test PostgreSQL failed to start' >&2
  exit 1
fi
run_sql() {
  docker exec -i "$RETIREMENT_CONTAINER" psql -X -U postgres -v ON_ERROR_STOP=1 < "$1"
}
python3 - "$RETIREMENT_ROOT" "$RETIREMENT_TMP/base.sql" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1])
source=(root/'supabase/migrations/20260402000000_initial_schema.sql').read_text()
start=source.index('CREATE TABLE IF NOT EXISTS external_sales (')
end=source.index('\n);',start)+3
Path(sys.argv[2]).write_text(source[start:end])
PY
run_sql "$RETIREMENT_ROOT/test/fixtures/deliberry_retirement_setup.sql" >/dev/null
run_sql "$RETIREMENT_TMP/base.sql" >/dev/null
run_sql "$RETIREMENT_ROOT/supabase/migrations/20260405000011_deliberry_settlement.sql" >/dev/null
run_sql "$RETIREMENT_ROOT/supabase/migrations/20260414000023_contract_store_naming_delivery_settlement.sql" >/dev/null
run_sql "$RETIREMENT_ROOT/supabase/migrations/20260614000000_deliberry_operational_order_d1.sql" >/dev/null
run_sql "$RETIREMENT_ROOT/test/fixtures/deliberry_retirement_seed.sql" >/dev/null
run_sql "$RETIREMENT_ROOT/scripts/preflight_deliberry_retirement.sql"
run_sql "$RETIREMENT_ROOT/supabase/migrations/20261005050000_deliberry_retirement.sql" >/dev/null
run_sql "$RETIREMENT_ROOT/scripts/verify_deliberry_retirement.sql"
run_sql "$RETIREMENT_ROOT/supabase/tests/deliberry_retirement_test.sql"
# Reapply is safe, and a server without pg_cron/optional operational tables is supported.
docker exec "$RETIREMENT_CONTAINER" psql -X -U postgres -v ON_ERROR_STOP=1 \
  -c 'DROP SCHEMA cron CASCADE; DROP TABLE public.deliberry_operational_order_events CASCADE; DROP TABLE public.deliberry_operational_orders CASCADE;' >/dev/null
run_sql "$RETIREMENT_ROOT/supabase/migrations/20261005050000_deliberry_retirement.sql" >/dev/null
run_sql "$RETIREMENT_ROOT/scripts/verify_deliberry_retirement.sql"
echo 'DELIBERRY_RETIREMENT_SQL_TEST=PASS'
