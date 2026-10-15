#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
onboarding_db="pos-store-onboarding-$$"
trap 'onboarding_exit=$?; if [[ "$onboarding_exit" != 0 ]]; then docker logs --tail 30 "$onboarding_db" 2>&1; fi; docker rm -f "$onboarding_db" >/dev/null 2>&1 || true' EXIT
docker run --detach --rm --name "$onboarding_db" --env POSTGRES_PASSWORD=fixture-only --env POSTGRES_DB=onboarding_test public.ecr.aws/supabase/postgres:17.6.1.104 >/dev/null
for attempt in $(seq 1 60); do
 if docker exec "$onboarding_db" pg_isready -h 127.0.0.1 -U postgres -d onboarding_test >/dev/null 2>&1; then break; fi
 if [[ "$attempt" == 60 ]]; then exit 1; fi
 sleep 1
done
run_sql() { docker exec -i "$onboarding_db" psql -X -v ON_ERROR_STOP=1 -U postgres -d onboarding_test; }
docker exec --env PGPASSWORD=fixture-only "$onboarding_db" psql -X -v ON_ERROR_STOP=1 -U supabase_admin -d onboarding_test -c 'ALTER DATABASE onboarding_test OWNER TO postgres' >/dev/null
docker exec --env PGPASSWORD=fixture-only "$onboarding_db" psql -X -v ON_ERROR_STOP=1 -U supabase_admin -d onboarding_test -c 'ALTER TABLE auth.users ADD COLUMN IF NOT EXISTS is_sso_user boolean NOT NULL DEFAULT false' >/dev/null
run_sql < test/fixtures/independent_brand_setup.sql >/dev/null
run_sql < test/fixtures/store_account_onboarding_setup.sql >/dev/null
python3 - <<'PY' | run_sql >/dev/null
from pathlib import Path
s=Path('supabase/migrations/20260711090000_legal_entity_brand_store_hierarchy.sql').read_text();a=s.index('CREATE OR REPLACE FUNCTION public.admin_create_restaurant_v2(');b=s.index('CREATE OR REPLACE FUNCTION public.admin_update_restaurant_v2(',a);print(s[a:b])
s=Path('supabase/migrations/20260414000004_add_multi_access_sync_functions.sql').read_text();a=s.index('CREATE OR REPLACE FUNCTION public.sync_user_store_access(');b=s.index('CREATE OR REPLACE FUNCTION public.sync_brand_store_access(',a);print(s[a:b])
s=Path('supabase/migrations/20261014081000_procurement_store_onboarding.sql').read_text();a=s.index('CREATE FUNCTION public.connect_procurement_stores(');b=s.index('CREATE FUNCTION public.procurement_onboarding_page',a);print(s[a:b])
PY
run_sql < supabase/migrations/20261015100000_independent_brand_registration.sql >/dev/null
run_sql < supabase/migrations/20261015150000_store_account_onboarding.sql >/dev/null
run_sql < supabase/migrations/20261015150000_store_account_onboarding.sql >/dev/null
run_sql <<'SQL' >/dev/null
CREATE TRIGGER station_assignment AFTER INSERT OR UPDATE OF fixed_account_code,restaurant_id,is_active ON users FOR EACH ROW EXECUTE FUNCTION sync_emergency_station_assignment_for_user();
SQL
run_sql < scripts/verify_store_account_onboarding.sql
run_sql < test/sql/store_account_onboarding_test.sql

race_store() {
 run_sql <<'SQL' >/dev/null
SELECT set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000001',false);
SET ROLE authenticated;
DO $$ BEGIN
 PERFORM admin_create_store_onboarding_v1(gen_random_uuid(),'Concurrent','address','JG03','50000000-0000-4000-8000-000000000001','40000000-0000-4000-8000-000000000001',ARRAY['1F']);
EXCEPTION WHEN OTHERS THEN
 IF SQLERRM<>'ABBREVIATION_EXISTS' THEN RAISE; END IF;
END $$;
SQL
}
race_store &
onboarding_race_pid=$!
race_store
wait "$onboarding_race_pid"
run_sql <<'SQL'
SELECT brand_assert((SELECT count(*)=1 FROM restaurants WHERE short_code='JG03'),'concurrent abbreviation has one store');
SELECT brand_assert((SELECT count(*)=1 FROM store_account_onboarding_jobs j JOIN restaurants r ON r.id=j.store_id WHERE r.short_code='JG03'),'concurrent abbreviation has one job');
SELECT 'STORE_ACCOUNT_ONBOARDING_CONCURRENCY=PASS';
BEGIN;
SELECT id AS purged_store_id FROM restaurants WHERE short_code='JG03' \gset
DELETE FROM store_fixed_account_requirements WHERE store_id=:'purged_store_id'::uuid;
DELETE FROM restaurants WHERE id=:'purged_store_id'::uuid;
SELECT brand_assert(NOT EXISTS(SELECT 1 FROM store_account_onboarding_jobs WHERE store_id=:'purged_store_id'::uuid),'onboarding history does not obstruct an authorized store purge');
ROLLBACK;
SQL
