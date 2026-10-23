#!/usr/bin/env bash
# Full live-schema, synthetic-data validation. Never connects to production.
set -euo pipefail
cd "$(dirname "$0")/.."
jgb_schema="${1:?Pass a public,pos_invoice_private schema-only export}"
jgb_output="${2:?Pass an output directory}"
[[ -f "$jgb_schema" ]] || exit 2
mkdir -p "$jgb_output"
jgb_run="pos-jgb-kds-load-$$"
jgb_db="$jgb_run-db"
jgb_rest="$jgb_run-rest"
jgb_stats_pid=""
cleanup() {
 if [[ -n "$jgb_stats_pid" ]]; then kill "$jgb_stats_pid" 2>/dev/null || true; fi
 docker rm -f "$jgb_rest" "$jgb_db" >/dev/null 2>&1 || true
 docker network rm "$jgb_run" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker network create "$jgb_run" >/dev/null
docker run --detach --rm --name "$jgb_db" --network "$jgb_run" --cpus=2 --memory=2g \
 --env POSTGRES_PASSWORD=jgb-fixture public.ecr.aws/supabase/postgres:17.6.1.104 \
 postgres -D /etc/postgresql -c shared_preload_libraries=pg_stat_statements \
 -c pg_stat_statements.track=all >/dev/null
for attempt in {1..60}; do
 if docker exec "$jgb_db" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1; then break; fi
 if [[ "$attempt" == 60 ]]; then exit 1; fi
 sleep 1
done
run_sql() { docker exec -i --env PGPASSWORD=jgb-fixture "$jgb_db" psql -X -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"; }
docker exec -i --env PGPASSWORD=jgb-fixture "$jgb_db" psql -X -U supabase_admin -d postgres -v ON_ERROR_STOP=1 \
 -c 'CREATE EXTENSION IF NOT EXISTS btree_gist; CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions; CREATE EXTENSION IF NOT EXISTS pg_stat_statements;' >/dev/null
docker exec -i --env PGPASSWORD=jgb-fixture "$jgb_db" psql -X -U supabase_admin -d postgres -v ON_ERROR_STOP=1 \
 < "$jgb_schema" > "$jgb_output/restore.log" 2>&1 || { tail -15 "$jgb_output/restore.log"; exit 1; }
# Match production Auth's claims fallback; the fixture image has older Auth.
docker exec -i --env PGPASSWORD=jgb-fixture "$jgb_db" psql -X -U supabase_admin -d postgres -v ON_ERROR_STOP=1 <<'SQL' >/dev/null
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
 SELECT coalesce(nullif(current_setting('request.jwt.claim.sub',true),''),
 (nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'sub'))::uuid $$;
CREATE OR REPLACE FUNCTION auth.role() RETURNS text LANGUAGE sql STABLE AS $$
 SELECT coalesce(nullif(current_setting('request.jwt.claim.role',true),''),
 (nullif(current_setting('request.jwt.claims',true),'')::jsonb->>'role')) $$;
SQL
run_sql -v historical=65 -v today=15 < test/fixtures/jeongabok_kds_sync_seed.sql > "$jgb_output/seed.log" 2>&1 || { tail -20 "$jgb_output/seed.log"; exit 1; }
run_sql < scripts/preflight_jeongabok_kds_bounded_sync.sql
run_sql < supabase/migrations/20261023080000_jeongabok_kds_bounded_sync.sql
run_sql < test/sql/jeongabok_kds_bounded_sync_test.sql > "$jgb_output/full-schema-parity.log"
run_sql < scripts/rollback_jeongabok_kds_bounded_sync.sql >/dev/null
run_sql < scripts/preflight_jeongabok_kds_bounded_sync.sql >/dev/null
run_sql < supabase/migrations/20261023080000_jeongabok_kds_bounded_sync.sql >/dev/null
docker run --detach --rm --name "$jgb_rest" --network "$jgb_run" --cpus=1 --memory=512m \
 --publish 127.0.0.1::3000 --env "PGRST_DB_URI=postgres://postgres@${jgb_db}:5432/postgres" \
 --env PGPASSWORD=jgb-fixture --env PGRST_DB_ANON_ROLE=anon --env PGRST_DB_SCHEMAS=public \
 --env PGRST_DB_POOL=10 --env PGRST_DB_POOL_ACQUISITION_TIMEOUT=10 \
 --env PGRST_JWT_SECRET=jgb-isolated-jwt-secret-for-local-load-test \
 public.ecr.aws/supabase/postgrest:v14.5 >/dev/null
jgb_address="$(docker port "$jgb_rest" 3000/tcp)"
for attempt in {1..60}; do
 if curl --fail --silent "http://$jgb_address/" >/dev/null; then break; fi
 if [[ "$attempt" == 60 ]]; then exit 1; fi
 sleep 1
done
docker stats --format '{{json .}}' "$jgb_db" "$jgb_rest" > "$jgb_output/memory-samples.jsonl" &
jgb_stats_pid=$!
for jgb_spec in 80:15 5000:38 50000:38 50000:120; do
 jgb_total="${jgb_spec%:*}";jgb_today="${jgb_spec#*:}"
 if [[ "$jgb_total" != 80 ]]; then
  python3 - "$jgb_output/incremental-seed.sql" <<'PY_SEED'
from pathlib import Path
import re,sys
s=Path('test/fixtures/jeongabok_kds_sync_seed.sql').read_text();s=s[s.index('INSERT INTO orders('):]
s=';'.join(x+' ON CONFLICT DO NOTHING' if re.search(r'(^|\n)INSERT INTO ',x) else x for x in s.split(';'))
Path(sys.argv[1]).write_text('SET session_replication_role=replica;\n'+s)
PY_SEED
  run_sql -v historical="$jgb_total" -v today=0 < "$jgb_output/incremental-seed.sql" > "$jgb_output/seed-$jgb_total-$jgb_today.log" 2>&1
  # Promote a fixed bounded set to the current civil day. Fixture only.
  run_sql -v first="$((jgb_total-jgb_today+16))" -v last="$jgb_total" <<'SQL' >/dev/null
SET session_replication_role=replica;
UPDATE orders SET created_at=now()-interval '10 days' WHERE id IN (SELECT order_id FROM emergency_order_queue WHERE queue_no>80);
UPDATE orders SET created_at=date_trunc('day',now() AT TIME ZONE 'Asia/Ho_Chi_Minh') AT TIME ZONE 'Asia/Ho_Chi_Minh' WHERE id IN (SELECT kds_test.id(n) FROM generate_series(:first,:last)n);
UPDATE emergency_order_queue q SET created_at=o.created_at FROM orders o WHERE o.id=q.order_id;
UPDATE order_items i SET created_at=o.created_at FROM orders o WHERE o.id=i.order_id;
UPDATE emergency_fulfillment_items i SET created_at=o.created_at FROM orders o WHERE o.id=i.order_id;
UPDATE emergency_fulfillment_events e SET created_at=o.created_at+CASE e.stage WHEN 'kitchen_done' THEN interval '100ms' ELSE interval '200ms' END FROM orders o WHERE o.id=e.order_id;
ANALYZE;
SQL
 fi
 jgb_observed="$(run_sql -qAt -c "SELECT count(*) FROM emergency_order_queue WHERE created_at>=date_trunc('day',now() AT TIME ZONE 'Asia/Ho_Chi_Minh') AT TIME ZONE 'Asia/Ho_Chi_Minh'")"
 [[ "$jgb_observed" == "$jgb_today" ]] || { printf 'Unexpected current day: %s expected %s\n' "$jgb_observed" "$jgb_today"; exit 1; }
 python3 scripts/tests/jeongabok_kds_sync_load.py "http://$jgb_address" "$jgb_output/http-$jgb_total-$jgb_today.json" --total "$jgb_total" --today "$jgb_today"
done
docker exec -i --env PGPASSWORD=jgb-fixture "$jgb_db" psql -X -U supabase_admin -d postgres -v ON_ERROR_STOP=1 <<'SQL' > "$jgb_output/nested-plan-call.log"
LOAD 'auto_explain';
SET auto_explain.log_min_duration=0;
SET auto_explain.log_analyze=on;
SET auto_explain.log_buffers=on;
SET auto_explain.log_nested_statements=on;
SET auto_explain.log_format=json;
SET request.jwt.claim.sub='ba000000-0000-4000-8000-000000900022';
SELECT jsonb_array_length(public.get_jeongabok_kds_completed_page_v1()->'orders'),jsonb_array_length(public.get_jeongabok_kds_bootstrap_v3()->'snapshot'->'orders');
SELECT jsonb_array_length(public.get_jeongabok_kds_tickets_v3(ARRAY(SELECT kds_test.id(200000+n) FROM generate_series(49951,50000)n))->'tickets');
SQL
docker logs "$jgb_db" > "$jgb_output/nested-plans.log" 2>&1
python3 scripts/tests/bunsik_kds_plan_summary.py "$jgb_output/nested-plans.log" "$jgb_output/nested-scan-summary.json"
run_sql -qAt <<'SQL' > "$jgb_output/statement-counts.json"
SELECT coalesce(jsonb_agg(x),'[]') FROM (SELECT calls,rows,round(mean_exec_time::numeric,3) mean_ms,round(max_exec_time::numeric,3) max_ms,left(query,180) query_prefix FROM pg_stat_statements WHERE query LIKE 'WITH pgrst_source%' ORDER BY query)x;
SQL
kill "$jgb_stats_pid" 2>/dev/null || true
jgb_stats_pid=""
python3 - "$jgb_output" <<'PY_MEMORY'
from pathlib import Path
import json,re,sys
out=Path(sys.argv[1]);peak={}
for line in (out/'memory-samples.jsonl').read_text().splitlines():
 try:r=json.loads(re.sub(r'\x1b\[[0-9;]*[A-Za-z]','',line))
 except json.JSONDecodeError:continue
 m=re.match(r'([0-9.]+)([A-Za-z]+)',r.get('MemUsage',''))
 if not m:continue
 factor={'B':1/1048576,'KiB':1/1024,'MiB':1,'GiB':1024,'kB':1000/1048576,'MB':1e6/1048576,'GB':1e9/1048576}[m[2]]
 key='database' if r['Name'].endswith('-db') else 'postgrest'
 peak[key]=max(peak.get(key,0),round(float(m[1])*factor,2))
(out/'memory-peaks.json').write_text(json.dumps({'sampled_container_peak_mib':peak,'method':'docker stats; includes DB cache, excludes Flutter heap'},indent=2)+'\n')
PY_MEMORY
printf 'JEONGABOK_KDS_FULL_SCHEMA_LOAD=PASS max_reads_per_terminal=1\n'
