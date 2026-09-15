#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
fixture_name="pos-menu-localization-$$"
fixture_log="$(mktemp)"
cleanup() { docker rm -f "$fixture_name" >/dev/null 2>&1 || true; rm -f "$fixture_log"; }
trap cleanup EXIT
docker run --detach --rm --name "$fixture_name" \
  --env POSTGRES_PASSWORD=menu-fixture --env POSTGRES_DB=menu_fixture \
  postgres:15 >/dev/null
for attempt in $(seq 1 60); do
  if docker exec "$fixture_name" pg_isready -U postgres -d menu_fixture >/dev/null 2>&1; then break; fi
  if [[ "$attempt" == 60 ]]; then exit 1; fi
  sleep 1
done
run_sql() { docker exec -i "$fixture_name" psql -X -v ON_ERROR_STOP=1 -U postgres -d menu_fixture; }
run_sql < test/fixtures/menu_localization_setup.sql >/dev/null
# Demonstrate the previous implementation loses translations before testing the fix.
run_sql < scripts/rollback_menu_display_localization.sql >/dev/null
if run_sql < test/sql/menu_localization_test.sql >"$fixture_log" 2>&1; then
  printf 'Expected the previous read functions to fail the translation regression.\n' >&2
  exit 1
fi
if ! grep -Eq 'English search lost|History translations lost' "$fixture_log"; then
  cat "$fixture_log" >&2
  exit 1
fi
for attempt in 1 2; do
  run_sql < supabase/migrations/20260915200000_menu_display_localization.sql >/dev/null
  run_sql < supabase/tests/bm_menu_exception_history_test.sql >/dev/null
  run_sql < test/sql/menu_localization_test.sql >/dev/null
  run_sql < scripts/verify_menu_display_localization.sql >/dev/null
done
run_sql < scripts/rollback_menu_display_localization.sql >/dev/null
run_sql < supabase/tests/bm_menu_exception_history_test.sql >/dev/null
run_sql < scripts/preflight_menu_display_localization.sql >/dev/null
run_sql < supabase/migrations/20260915200000_menu_display_localization.sql >/dev/null
run_sql < test/sql/menu_localization_test.sql >/dev/null
printf 'MENU_LOCALIZATION_SQL_TEST=PASS\n'
