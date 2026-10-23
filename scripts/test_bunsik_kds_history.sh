#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
fixture="pos-bunsik-history-$$"
scratch="$(mktemp -d)"
cleanup() { docker rm -f "$fixture" >/dev/null 2>&1 || true; rm -rf "$scratch"; }
trap cleanup EXIT
docker run --detach --rm --network none --name "$fixture" --cpus=2 --memory=2g \
 --env POSTGRES_PASSWORD=fixture-only postgres:15 >/dev/null
for attempt in {1..60}; do
 if docker exec "$fixture" pg_isready -U postgres >/dev/null 2>&1; then break; fi
 if [[ "$attempt" == 60 ]]; then exit 1; fi
 sleep 1
done
run_sql() { docker exec -i "$fixture" psql -X -U postgres -v ON_ERROR_STOP=1 "$@"; }
run_sql < test/fixtures/bunsik_kds_history_setup.sql > "$scratch/setup.log" 2>&1 || { tail -15 "$scratch/setup.log"; exit 1; }
run_sql < supabase/migrations/20261023060000_bunsik_kds_bounded_history.sql >/dev/null
run_sql -v historical=4463 -v today=300 < test/fixtures/bunsik_kds_history_seed.sql > "$scratch/seed.log" 2>&1 || { tail -15 "$scratch/seed.log"; exit 1; }
run_sql < test/sql/bunsik_kds_history_test.sql
printf 'BUNSIK_KDS_HISTORY_FIXTURE=PASS historical=4463 today=300 network=none\n'

