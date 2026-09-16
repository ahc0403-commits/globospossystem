#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTAINER="qr-menu-sync-$RANDOM-$$"

cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker run --detach --rm \
  --name "$CONTAINER" \
  --env POSTGRES_HOST_AUTH_METHOD=trust \
  postgres:15 >/dev/null

for _ in {1..30}; do
  if docker exec "$CONTAINER" pg_isready -U postgres >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

run_sql() {
  docker exec -i "$CONTAINER" \
    psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres
}

run_sql < "$ROOT_DIR/test/fixtures/qr_menu_category_auto_sync_setup.sql" \
  >/dev/null
run_sql < "$ROOT_DIR/scripts/preflight_qr_menu_category_auto_sync.sql" \
  >/dev/null
run_sql < "$ROOT_DIR/supabase/migrations/20260916130000_qr_menu_category_auto_sync.sql" \
  >/dev/null
run_sql < "$ROOT_DIR/scripts/verify_qr_menu_category_auto_sync.sql" \
  >/dev/null
run_sql < "$ROOT_DIR/test/sql/qr_menu_category_auto_sync_test.sql" \
  >/dev/null

printf 'QR menu category auto-sync SQL test passed.\n'
