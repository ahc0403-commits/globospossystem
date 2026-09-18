#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

fixture_name="pos-menu-item-archive-$$"
cleanup() {
  docker rm -f "$fixture_name" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker run --detach --rm --name "$fixture_name" \
  --env POSTGRES_PASSWORD=menu-archive-fixture \
  --env POSTGRES_DB=menu_archive_fixture \
  postgres:15 >/dev/null

for attempt in $(seq 1 60); do
  if docker exec "$fixture_name" \
    psql -X -v ON_ERROR_STOP=1 -U postgres -d menu_archive_fixture \
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
    psql -X -v ON_ERROR_STOP=1 -U postgres -d menu_archive_fixture
}

run_sql < test/fixtures/menu_localization_setup.sql >/dev/null
run_sql < test/fixtures/admin_menu_item_archive_setup.sql >/dev/null
run_sql < scripts/preflight_admin_menu_item_archive.sql >/dev/null
run_sql < supabase/migrations/20260918020000_admin_menu_item_archive.sql >/dev/null
run_sql < supabase/tests/admin_menu_item_archive_test.sql >/dev/null
run_sql < scripts/verify_admin_menu_item_archive.sql >/dev/null
run_sql < scripts/rollback_admin_menu_item_archive.sql >/dev/null
run_sql < scripts/preflight_admin_menu_item_archive.sql >/dev/null
run_sql < supabase/migrations/20260918020000_admin_menu_item_archive.sql >/dev/null
run_sql < scripts/verify_admin_menu_item_archive.sql >/dev/null

printf 'ADMIN_MENU_ITEM_ARCHIVE_SQL_TEST=PASS\n'
