#!/usr/bin/env bash
# Full live-schema, synthetic-data validation. Never connects to production.
set -euo pipefail
cd "$(dirname "$0")/.."
bunsik_schema="${1:?Pass a public,pos_invoice_private schema-only export}"
bunsik_output="${2:?Pass an output directory}"
[[ -f "$bunsik_schema" ]] || exit 2
mkdir -p "$bunsik_output"
cp supabase/migrations/20261023060000_bunsik_kds_bounded_history.sql "$bunsik_output/input-migration.sql"
cp scripts/preflight_bunsik_kds_bounded_history.sql "$bunsik_output/input-preflight.sql"
cp scripts/rollback_bunsik_kds_bounded_history.sql "$bunsik_output/input-rollback.sql"
cp test/fixtures/bunsik_kds_history_seed.sql "$bunsik_output/input-seed.sql"
cp test/sql/bunsik_kds_history_test.sql "$bunsik_output/input-test.sql"
cp scripts/tests/bunsik_kds_history_load.py "$bunsik_output/input-load.py"
bunsik_run="pos-bunsik-kds-load-$$"
bunsik_db="$bunsik_run-db"
bunsik_rest="$bunsik_run-rest"
bunsik_stats_pid=""
cleanup() {
 if [[ -n "$bunsik_stats_pid" ]]; then kill "$bunsik_stats_pid" 2>/dev/null || true; fi
 docker rm -f "$bunsik_rest" "$bunsik_db" >/dev/null 2>&1 || true
 docker network rm "$bunsik_run" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker network create "$bunsik_run" >/dev/null
docker run --detach --rm --name "$bunsik_db" --network "$bunsik_run" --cpus=2 --memory=2g \
 --env POSTGRES_PASSWORD=bunsik-fixture public.ecr.aws/supabase/postgres:17.6.1.104 \
 postgres -D /etc/postgresql -c shared_preload_libraries=pg_stat_statements \
 -c pg_stat_statements.track=all >/dev/null
for attempt in {1..60}; do
 if docker exec "$bunsik_db" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1; then break; fi
 if [[ "$attempt" == 60 ]]; then exit 1; fi
 sleep 1
done
run_sql() { docker exec -i --env PGPASSWORD=bunsik-fixture "$bunsik_db" psql -X -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
docker exec -i --env PGPASSWORD=bunsik-fixture "$bunsik_db" psql -X -U supabase_admin -d postgres -v ON_ERROR_STOP=1 \
 -c 'CREATE EXTENSION IF NOT EXISTS btree_gist; CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions; CREATE EXTENSION IF NOT EXISTS pg_stat_statements;' >/dev/null
docker exec -i --env PGPASSWORD=bunsik-fixture "$bunsik_db" psql -X -U supabase_admin -d postgres -v ON_ERROR_STOP=1 \
 < "$bunsik_schema" > "$bunsik_output/restore.log" 2>&1 || { tail -15 "$bunsik_output/restore.log"; exit 1; }
# Match production Auth's claims fallback; the fixture image has older Auth.
docker exec -i --env PGPASSWORD=bunsik-fixture "$bunsik_db" psql -X -U supabase_admin -d postgres -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
 SELECT coalesce(nullif(current_setting('request.jwt.claim.sub',true),''),
 (nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'sub'))::uuid $$;
CREATE OR REPLACE FUNCTION auth.role() RETURNS text LANGUAGE sql STABLE AS $$
 SELECT coalesce(nullif(current_setting('request.jwt.claim.role',true),''),
 (nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'role')) $$;
SQL
run_sql -v historical=4463 -v today=120 < "$bunsik_output/input-seed.sql" > "$bunsik_output/seed-4463.log" 2>&1
run_sql < "$bunsik_output/input-preflight.sql" >/dev/null
run_sql < "$bunsik_output/input-migration.sql" >/dev/null
run_sql < "$bunsik_output/input-test.sql" > "$bunsik_output/full-schema-parity.log"
run_sql < "$bunsik_output/input-rollback.sql" >/dev/null
run_sql < "$bunsik_output/input-preflight.sql" >/dev/null
run_sql < "$bunsik_output/input-migration.sql" >/dev/null
run_sql < "$bunsik_output/input-test.sql" >> "$bunsik_output/full-schema-parity.log"
docker run --detach --rm --name "$bunsik_rest" --network "$bunsik_run" --cpus=1 --memory=512m \
 --publish 127.0.0.1::3000 --env "PGRST_DB_URI=postgres://postgres@${bunsik_db}:5432/postgres" \
 --env PGPASSWORD=bunsik-fixture --env PGRST_DB_ANON_ROLE=anon --env PGRST_DB_SCHEMAS=public \
 --env PGRST_DB_POOL=10 --env PGRST_DB_POOL_ACQUISITION_TIMEOUT=10 \
 --env PGRST_JWT_SECRET=bunsik-isolated-jwt-secret-for-local-load-test \
 public.ecr.aws/supabase/postgrest:v14.5 >/dev/null
bunsik_address="$(docker port "$bunsik_rest" 3000/tcp)"
for attempt in {1..60}; do
 if curl --fail --silent "http://$bunsik_address/" >/dev/null; then break; fi
 if [[ "$attempt" == 60 ]]; then exit 1; fi
 sleep 1
done
docker stats --format '{{json .}}' "$bunsik_db" "$bunsik_rest" > "$bunsik_output/memory-samples.jsonl" &
bunsik_stats_pid=$!
for bunsik_history in 4463 5000 50000; do
 if [[ "$bunsik_history" != 4463 ]]; then
  # Keep today's exact rows stable. Add older synthetic rows without deleting
  # through production financial/retention guards or copying business data.
  python3 - "$bunsik_output/incremental-seed.sql" "$bunsik_output/input-seed.sql" <<'PY'
from pathlib import Path
import re,sys
source=Path(sys.argv[2]).read_text()
source=source[source.index('INSERT INTO orders('):]
parts=[s+' ON CONFLICT DO NOTHING' if re.search(r'(^|\n)INSERT INTO ',s) else s for s in source.split(';')]
Path(sys.argv[1]).write_text('SET session_replication_role=replica;\n'+';'.join(parts))
PY
  run_sql -v historical="$((bunsik_history+120))" -v today=0 < "$bunsik_output/incremental-seed.sql" \
   > "$bunsik_output/seed-$bunsik_history.log" 2>&1 || { tail -15 "$bunsik_output/seed-$bunsik_history.log"; exit 1; }
 fi
 python3 "$bunsik_output/input-load.py" "http://$bunsik_address" \
  "$bunsik_output/http-$bunsik_history.json" --historical "$bunsik_history" --today 120
 run_sql -qAt <<'SQL' > "$bunsik_output/plan-history-$bunsik_history.json"
BEGIN READ ONLY;
SET LOCAL request.jwt.claim.sub='ba000000-0000-4000-8000-000000900022';
EXPLAIN (ANALYZE,BUFFERS,FORMAT JSON) SELECT public.get_bunsik_kds_completed_page_v1();
ROLLBACK;
SQL
 run_sql -qAt <<'SQL' > "$bunsik_output/plan-snapshot-$bunsik_history.json"
BEGIN READ ONLY;
SET LOCAL request.jwt.claim.sub='ba000000-0000-4000-8000-000000900022';
EXPLAIN (ANALYZE,BUFFERS,FORMAT JSON) SELECT public.get_emergency_station_snapshot();
ROLLBACK;
SQL
 run_sql -qAt <<'SQL' > "$bunsik_output/statement-counts-$bunsik_history.json"
SELECT coalesce(jsonb_agg(x),'[]') FROM (
 SELECT calls,rows,round(mean_exec_time::numeric,3) mean_ms,round(max_exec_time::numeric,3) max_ms,
  left(query,180) query_prefix FROM pg_stat_statements
 WHERE query LIKE 'WITH pgrst_source%' ORDER BY query
)x;
SQL
done

# Inspect actual nested execution at the largest data set. Aggregate findings
# exclude JSON fixture payloads; fail if a history/snapshot scans broad ledgers.
docker exec -i --env PGPASSWORD=bunsik-fixture "$bunsik_db" psql -X -U supabase_admin -d postgres -v ON_ERROR_STOP=1 <<'SQL' > "$bunsik_output/nested-plan-call.log"
LOAD 'auto_explain';
SET auto_explain.log_min_duration=0;
SET auto_explain.log_analyze=on;
SET auto_explain.log_buffers=on;
SET auto_explain.log_nested_statements=on;
SET auto_explain.log_format=json;
SET request.jwt.claim.sub='ba000000-0000-4000-8000-000000900022';
SELECT jsonb_array_length(public.get_bunsik_kds_completed_page_v1()->'orders'),
 jsonb_array_length(public.get_emergency_station_snapshot()->'orders');
SQL
docker logs "$bunsik_db" > "$bunsik_output/nested-plans.log" 2>&1
python3 scripts/tests/bunsik_kds_plan_summary.py "$bunsik_output/nested-plans.log" "$bunsik_output/nested-scan-summary.json"

kill "$bunsik_stats_pid" 2>/dev/null || true
bunsik_stats_pid=""
python3 - "$bunsik_output" <<'PY'
from pathlib import Path
import json,re,sys
out=Path(sys.argv[1]);peak={}
for line in (out/'memory-samples.jsonl').read_text().splitlines():
 try:r=json.loads(re.sub(r'\x1b\[[0-9;]*[A-Za-z]','',line))
 except json.JSONDecodeError:continue
 match=re.match(r'([0-9.]+)([A-Za-z]+)',r.get('MemUsage',''))
 if not match:continue
 factor={'B':1/1048576,'KiB':1/1024,'MiB':1,'GiB':1024,'kB':1000/1048576,'MB':1e6/1048576,'GB':1e9/1048576}[match[2]]
 key='database' if r['Name'].endswith('-db') else 'postgrest'
 peak[key]=max(peak.get(key,0),round(float(match[1])*factor,2))
(out/'memory-peaks.json').write_text(json.dumps({'sampled_container_peak_mib':peak,
 'method':'docker stats sampled during HTTP runs; includes PostgreSQL shared/cache memory; not Flutter heap'},indent=2)+'\n')
print('BUNSIK_KDS_FULL_SCHEMA_LOAD=PASS rollback_reapply=PASS errors=0 max_reads_per_terminal=2')
PY
