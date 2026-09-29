#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
test_container="pos-bunsik-ledger-name-$$"
cleanup() { docker rm -f "$test_container" >/dev/null 2>&1 || true; }
trap cleanup EXIT
docker run --detach --rm --name "$test_container" \
  --env POSTGRES_HOST_AUTH_METHOD=trust postgres:15 >/dev/null
for attempt in $(seq 1 60); do
  if docker exec "$test_container" pg_isready -U postgres >/dev/null 2>&1; then break; fi
  [[ "$attempt" != 60 ]] || exit 1
  sleep 1
done
run_sql() { docker exec -i "$test_container" psql -X -U postgres -v ON_ERROR_STOP=1; }
run_sql < test/fixtures/menu_localization_setup.sql >/dev/null
run_sql < supabase/migrations/20260915200000_menu_display_localization.sql >/dev/null
run_sql < test/fixtures/bunsik_receipt_ledger_names_test.sql >/dev/null
run_sql < supabase/migrations/20260929030000_bunsik_receipt_ledger_names.sql >/dev/null
run_sql < scripts/verify_bunsik_receipt_ledger_names.sql >/dev/null
run_sql < test/fixtures/bunsik_receipt_ledger_names_assertions.sql >/dev/null
printf 'BUNSIK_RECEIPT_LEDGER_NAMES_SQL_TEST=PASS\n'
