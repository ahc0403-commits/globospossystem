#!/usr/bin/env bash
set -euo pipefail
brand_repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$brand_repo_root"
brand_db_name="pos-independent-brand-$$"
trap 'brand_exit=$?; if [[ "$brand_exit" != 0 ]]; then docker logs --tail 60 "$brand_db_name" 2>&1; fi; docker rm -f "$brand_db_name" >/dev/null 2>&1 || true' EXIT
docker run --detach --rm --name "$brand_db_name" \
  --env POSTGRES_PASSWORD=brand-fixture --env POSTGRES_DB=brand_test \
  public.ecr.aws/supabase/postgres:17.6.1.104 >/dev/null
for attempt in $(seq 1 60); do
  if docker exec "$brand_db_name" pg_isready -h 127.0.0.1 -U postgres -d brand_test >/dev/null 2>&1; then break; fi
  if [[ "$attempt" == 60 ]]; then exit 1; fi
  sleep 1
done
run_sql() { docker exec -i "$brand_db_name" psql -X -v ON_ERROR_STOP=1 -U postgres -d brand_test; }
docker exec --env PGPASSWORD=brand-fixture "$brand_db_name" psql -X -v ON_ERROR_STOP=1 -U supabase_admin -d brand_test \
  -c 'ALTER DATABASE brand_test OWNER TO postgres' >/dev/null
run_sql < test/fixtures/independent_brand_setup.sql >/dev/null
# Exercise the existing store mutation, not a duplicate implementation.
python3 - <<'PY' | run_sql >/dev/null
from pathlib import Path
source=Path('supabase/migrations/20260711090000_legal_entity_brand_store_hierarchy.sql').read_text()
start=source.index('CREATE OR REPLACE FUNCTION public.admin_create_restaurant_v2(')
end=source.index('CREATE OR REPLACE FUNCTION public.admin_update_restaurant_v2(',start)
print(source[start:end])
PY
run_sql < supabase/migrations/20261015100000_independent_brand_registration.sql >/dev/null
run_sql < supabase/migrations/20261015100000_independent_brand_registration.sql >/dev/null
run_sql < test/sql/independent_brand_test.sql
# Two sessions race for the same normalized code. Exactly one row and audit
# must commit; the losing session must get the expected duplicate-code error.
race_create() {
  run_sql <<'SQL' >/dev/null
SELECT set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000001',false);
SET ROLE authenticated;
DO $$ BEGIN
  PERFORM admin_create_brand_v1(gen_random_uuid(),'Concurrent brand','concurrent_brand',
    '30000000-0000-4000-8000-000000000001');
EXCEPTION WHEN OTHERS THEN
  IF SQLERRM <> 'BRAND_CODE_EXISTS' THEN RAISE; END IF;
END $$;
SQL
}
race_create &
brand_race_pid=$!
race_create
wait "$brand_race_pid"
run_sql <<'SQL'
SELECT brand_assert((SELECT count(*)=1 FROM brands WHERE code='concurrent_brand'),'concurrent code race');
SELECT brand_assert((SELECT count(*)=1 FROM audit_logs WHERE action='admin_create_brand_v1' AND details->>'code'='concurrent_brand'),'concurrent audit count');
SELECT 'INDEPENDENT_BRAND_CONCURRENCY=PASS';
SQL
