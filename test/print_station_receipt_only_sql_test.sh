#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
station_db="pos-station-receipt-test-$$"
trap 'docker rm -f "$station_db" >/dev/null 2>&1 || true' EXIT
docker run --detach --rm --name "$station_db" --env POSTGRES_PASSWORD=station-fixture --env POSTGRES_DB=station_test public.ecr.aws/supabase/postgres:17.6.1.104 >/dev/null
for attempt in $(seq 1 45); do
 if docker exec "$station_db" psql -X -U postgres -d station_test -Atqc "SELECT 1" >/dev/null 2>&1; then break; fi
 if [[ "$attempt" == 45 ]]; then exit 1; fi
 sleep 1
done
run_sql() { docker exec -i "$station_db" psql -X -v ON_ERROR_STOP=1 -U postgres -d station_test "$@"; }
docker exec --env PGPASSWORD=station-fixture "$station_db" psql -X -v ON_ERROR_STOP=1 -U supabase_admin -d station_test -c 'ALTER DATABASE station_test OWNER TO postgres; GRANT USAGE ON SCHEMA auth TO postgres' >/dev/null
run_sql <<'SQL'
DO $$ BEGIN
 IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon; END IF;
 IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated; END IF;
 IF NOT EXISTS(SELECT FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role; END IF;
END $$;
CREATE TABLE printer_destinations(id uuid PRIMARY KEY, restaurant_id uuid, purpose text, is_active boolean);
CREATE TABLE print_jobs(id uuid PRIMARY KEY,restaurant_id uuid,destination_id uuid,copy_type text,payload jsonb DEFAULT '{}',status text DEFAULT 'pending',next_retry_at timestamptz DEFAULT now(),attempts int DEFAULT 0,emergency_held_at timestamptz,created_at timestamptz DEFAULT now(),updated_at timestamptz,claimed_by uuid);
CREATE INDEX print_jobs_pending ON print_jobs(restaurant_id,created_at,id) WHERE status IN ('pending','failed');
CREATE FUNCTION print_routing_actor_can_run(uuid) RETURNS boolean LANGUAGE sql STABLE AS $$ SELECT auth.uid()='00000000-0000-0000-0000-000000000001'::uuid AND $1='20000000-0000-0000-0000-000000000001'::uuid $$;
SQL
# Reuse the real routing baseline and the effective v3 payload capability guard.
python3 - <<'PY' | run_sql
from pathlib import Path
s=Path('supabase/migrations/20260811170000_pos_paperless_receipts.sql').read_text()
s=s[s.index('CREATE OR REPLACE FUNCTION public.claim_print_jobs('):]
s=s[:s.index('\n$$;')+4]
s=s.replace('public.claim_print_jobs(', 'public.claim_print_jobs_v3(').replace('AND emergency_held_at IS NULL', "AND emergency_held_at IS NULL AND COALESCE((payload->>'receipt_payload_version')::integer,1)<=2")
print(s)
PY
run_sql < supabase/migrations/20261019100000_print_station_receipt_only.sql
run_sql < supabase/migrations/20261019100000_print_station_receipt_only.sql
run_sql < test/sql/print_station_receipt_only_test.sql
