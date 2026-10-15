#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

fixture_name="pos-kds-tray-partial-$$"
cleanup() {
  docker rm -f "$fixture_name" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker run --detach --rm --name "$fixture_name" \
  --env POSTGRES_PASSWORD=kds-tray-partial-fixture \
  --env POSTGRES_DB=kds_tray_partial_fixture \
  postgres:15 >/dev/null

for attempt in $(seq 1 60); do
  if docker exec "$fixture_name" \
    psql -X -v ON_ERROR_STOP=1 -U postgres -d kds_tray_partial_fixture \
      -c 'SELECT 1' >/dev/null 2>&1; then
    break
  fi
  if [[ "$attempt" == 60 ]]; then
    exit 1
  fi
  sleep 1
done

run_sql() {
  docker exec -i "$fixture_name" \
    psql -X -v ON_ERROR_STOP=1 -U postgres -d kds_tray_partial_fixture
}

run_sql < test/fixtures/kds_tray_floor_partial_batch_setup.sql >/dev/null
run_sql < scripts/preflight_kds_tray_floor_partial_batch.sql >/dev/null
run_sql < supabase/migrations/20260919010000_kds_tray_floor_partial_batch.sql \
  >/dev/null
run_sql < scripts/verify_kds_tray_floor_partial_batch.sql >/dev/null
run_sql < supabase/tests/kds_tray_floor_partial_batch_test.sql >/dev/null

# Apply the actual onboarding floor extension to the predecessor KDS contract.
# Re-run its stale/idempotency scenarios on 3F and reject a 1F -> 3F allocation.
run_sql <<'SQL' >/dev/null
CREATE TABLE public.kds_shadow_health(floor_key text CHECK(floor_key IN('','1F','2F')));
CREATE TABLE public.kds_change_log(target_floor_label text CHECK(target_floor_label IS NULL OR target_floor_label IN('1F','2F')));
ALTER TABLE public.emergency_order_queue ADD CHECK(floor_label IN('1F','2F'));
DO $$ BEGIN
 EXECUTE replace(pg_get_functiondef('public.kds_dispatch_tray_floor_batch_v1(uuid,text,jsonb)'::regprocedure),'FUNCTION public.kds_dispatch_tray_floor_batch_v1(', 'FUNCTION public.kds_dispatch_tray_floor_loop_backup_v1(');
END $$;
SQL
python3 - <<'PYFLOOR' | run_sql >/dev/null
from pathlib import Path
s=Path('supabase/migrations/20261015150000_store_account_onboarding.sql').read_text()
a=s.index('DO $floors$');b=s.index('END $floors$;',a)+len('END $floors$;');print(s[a:b])
PYFLOOR
run_sql <<'SQL' >/dev/null
BEGIN;
SELECT set_config('request.jwt.claim.sub','10000000-0000-0000-0000-000000000002',true);
DO $$ BEGIN
 BEGIN
  PERFORM public.kds_dispatch_tray_floor_batch_v1(gen_random_uuid(),'3F','[{"item_id":"10000000-0000-0000-0000-000000000008","queue_id":"10000000-0000-0000-0000-000000000007","source_kind":"base","quantity":1}]'::jsonb);
  RAISE EXCEPTION 'CROSS_FLOOR_DISPATCH_ALLOWED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'KDS_TRAY_FLOOR_BATCH_STALE' THEN RAISE; END IF; END;
 IF pg_get_functiondef('public.kds_dispatch_tray_floor_loop_backup_v1(uuid,text,jsonb)'::regprocedure) NOT LIKE '%''3F''%' THEN RAISE EXCEPTION 'LEGACY_GUARD_NOT_EXTENDED'; END IF;
END $$;
ROLLBACK;
UPDATE public.emergency_order_queue SET floor_label='3F';
SQL
python3 - <<'PYFLOOR' | run_sql >/dev/null
from pathlib import Path
print(Path('supabase/tests/kds_tray_floor_partial_batch_test.sql').read_text().replace("'1F'","'3F'"))
PYFLOOR
run_sql <<'SQL' >/dev/null
UPDATE public.emergency_order_queue SET floor_label='1F';
SQL
printf 'KDS_THIRD_FLOOR_ISOLATION=PASS\n'
run_sql < scripts/rollback_kds_tray_floor_partial_batch.sql >/dev/null
run_sql < scripts/preflight_kds_tray_floor_partial_batch.sql >/dev/null
run_sql < supabase/migrations/20260919010000_kds_tray_floor_partial_batch.sql \
  >/dev/null
run_sql < scripts/verify_kds_tray_floor_partial_batch.sql >/dev/null
run_sql < supabase/tests/kds_tray_floor_partial_batch_test.sql >/dev/null

printf 'KDS_TRAY_FLOOR_PARTIAL_BATCH_SQL_TEST=PASS\n'
