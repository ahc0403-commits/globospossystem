#!/usr/bin/env bash
set -euo pipefail
SALES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SALES_CONTAINER="pos-finalization-test-$$"
trap 'docker rm -f "$SALES_CONTAINER" >/dev/null 2>&1 || true' EXIT
docker run --rm -d --name "$SALES_CONTAINER" -e POSTGRES_HOST_AUTH_METHOD=trust postgres:17-alpine >/dev/null
for attempt in {1..30}; do
 if docker exec "$SALES_CONTAINER" pg_isready -U postgres >/dev/null 2>&1; then break; fi
 sleep 1
done
SALES_PSQL=(docker exec -i "$SALES_CONTAINER" psql -X -U postgres -v ON_ERROR_STOP=1)
"${SALES_PSQL[@]}" -c 'create role anon;create role authenticated;create role service_role bypassrls;' >/dev/null
"${SALES_PSQL[@]}" < "$SALES_ROOT/supabase/tests/fixtures/restaurant_sales_finalization.sql" >/dev/null
"${SALES_PSQL[@]}" < "$SALES_ROOT/supabase/migrations/20261019090000_restaurant_sales_finalization_source.sql" >/dev/null
"${SALES_PSQL[@]}" < "$SALES_ROOT/supabase/tests/restaurant_sales_finalization_source.sql"
for attempt in 1 2; do
 "${SALES_PSQL[@]}" < "$SALES_ROOT/supabase/migrations/20261019091000_repair_empty_restaurant_finalizations.sql" >/dev/null
done
"${SALES_PSQL[@]}" < "$SALES_ROOT/supabase/tests/restaurant_sales_finalization_repair.sql"
"${SALES_PSQL[@]}" < "$SALES_ROOT/supabase/tests/restaurant_sales_finalization_performance.sql"
