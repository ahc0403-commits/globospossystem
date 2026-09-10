#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTAINER="globos-inventory-orderer-catalog-$$"

cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker run --detach --rm \
  --name "$CONTAINER" \
  --env POSTGRES_HOST_AUTH_METHOD=trust \
  --publish 127.0.0.1::5432 \
  postgres:15 >/dev/null

PORT="$(docker port "$CONTAINER" 5432/tcp | sed 's/.*://')"
ready=0
for ((attempt = 0; attempt < 100; attempt++)); do
  if psql -h 127.0.0.1 -p "$PORT" -U postgres -Atqc 'SELECT 1' \
    >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.2
done
[[ "$ready" == 1 ]]

run_sql() {
  psql -X -h 127.0.0.1 -p "$PORT" -U postgres \
    -v ON_ERROR_STOP=1 --file "$1"
}

run_sql \
  "$ROOT_DIR/test/fixtures/inventory_purchase_orderer_catalog_setup.sql" \
  >/dev/null
run_sql \
  "$ROOT_DIR/supabase/migrations/20260910120000_inventory_purchase_orderer_catalog_access.sql" \
  >/dev/null
run_sql \
  "$ROOT_DIR/test/fixtures/inventory_purchase_orderer_catalog_assertions.sql"
