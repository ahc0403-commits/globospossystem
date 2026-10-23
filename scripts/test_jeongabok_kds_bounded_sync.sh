#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
jgb_fixture="pos-jgb-bounded-$$"
jgb_scratch="$(mktemp -d)"
cleanup() { docker rm -f "$jgb_fixture" >/dev/null 2>&1 || true; rm -rf "$jgb_scratch"; }
trap cleanup EXIT
docker run --detach --rm --network none --name "$jgb_fixture" --cpus=2 --memory=2g \
 --env POSTGRES_PASSWORD=fixture-only postgres:15 >/dev/null
for attempt in {1..60}; do
 if docker exec "$jgb_fixture" pg_isready -U postgres >/dev/null 2>&1; then break; fi
 if [[ "$attempt" == 60 ]]; then exit 1; fi
 sleep 1
done
run_sql() { docker exec -i "$jgb_fixture" psql -X -U postgres -v ON_ERROR_STOP=1 "$@"; }
{
 run_sql < test/fixtures/bunsik_kds_history_setup.sql
 run_sql < test/fixtures/jeongabok_kds_sync_setup.sql
 run_sql -v historical=65 -v today=120 < test/fixtures/jeongabok_kds_sync_seed.sql
 run_sql < scripts/preflight_jeongabok_kds_bounded_sync.sql
 run_sql < supabase/migrations/20261023080000_jeongabok_kds_bounded_sync.sql
 run_sql < test/sql/jeongabok_kds_bounded_sync_test.sql
 run_sql < scripts/rollback_jeongabok_kds_bounded_sync.sql
 run_sql < scripts/preflight_jeongabok_kds_bounded_sync.sql
 run_sql < supabase/migrations/20261023080000_jeongabok_kds_bounded_sync.sql
 run_sql < test/sql/jeongabok_kds_bounded_sync_test.sql
} > "$jgb_scratch/result.log" 2>&1 || { tail -20 "$jgb_scratch/result.log"; exit 1; }
printf 'JEONGABOK_KDS_BOUNDED_SYNC=PASS rollback_reapply=PASS\n'
