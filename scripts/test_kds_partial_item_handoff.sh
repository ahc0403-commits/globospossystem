#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
fixture="pos-kds-partial-$$"
scratch="$(mktemp -d)"
cleanup() { docker rm -f "$fixture" >/dev/null 2>&1 || true; rm -rf "$scratch"; }
trap cleanup EXIT
# Schema/functions and synthetic rows only; no network or production workers.
docker run --detach --rm --network none --name "$fixture" \
 --env POSTGRES_PASSWORD=isolated-fixture postgres:15 >/dev/null
for attempt in {1..60}; do
 if docker exec "$fixture" pg_isready -U postgres >/dev/null 2>&1; then break; fi
 if [[ "$attempt" == 60 ]]; then exit 1; fi
 sleep 1
done
run_sql() { docker exec -i "$fixture" psql -X -U postgres -v ON_ERROR_STOP=1 "$@"; }
run_sql < test/fixtures/kds_partial_item_handoff_setup.sql >/dev/null
python3 - <<'PY' > "$scratch/baseline.sql"
from pathlib import Path
import re
def fn(path,name):
 s=Path('supabase/migrations/'+path+'.sql').read_text()
 m=re.search(r'CREATE (?:OR REPLACE )?FUNCTION (?:public|"public")\.(?:"'+name+r'"|'+name+r')\(',s,re.I)
 assert m,name
 return s[m.start():s.index('$$;',m.start())+3]+'\n'
single=fn('20260917150000_kds_kitchen_complete_tray_handoff_batch','kds_record_station_progress_v3')
direct=Path('supabase/migrations/20261020090000_jeongabok_kitchen_floor.sql').read_text()
m=re.search(r"SELECT pg_temp.kds_direct_patch\('public.kds_record_station_progress_v3.*?\$old\$(.*?)\$old\$,\s*\$new\$(.*?)\$new\$\);",direct,re.S)
assert m and single.count(m[1])==1
single=single.replace(m[1],m[2])
explicit=Path('supabase/migrations/20261021130000_jeongabok_explicit_floor_handoff.sql').read_text()
m=re.search(r"'public.kds_record_station_progress_v3.*?\$old\$(.*?)\$old\$,\s*\$new\$(.*?)\$new\$\);",explicit,re.S)
assert m and single.count(m[1])==1
single=single.replace(m[1],m[2])
single=single.replace('v_assignment.floor_label <> v_queue.floor_label',
 'NOT (v_queue.floor_label=ANY(public.store_assignment_area_codes_v1(v_assignment)))')
print(single)
print(fn('20261021130000_jeongabok_explicit_floor_handoff','kds_record_direct_preparation_v1'))
print(fn('20261020090000_jeongabok_kitchen_floor','kds_record_direct_kitchen_v1'))
print(fn('20260920100000_kds_subsecond_set_based_delivery','kds_complete_kitchen_batch_v1'))
print(fn('20261021191000_multi_kitchen_progress','kds_apply_station_progress_batch_v1'))
bulk=fn('20260916190000_kds_start_ready_serve_workflow','kds_serve_ready_order_v3')
bulk=bulk.replace('v_queue.floor_label <> v_assignment.floor_label',
 'NOT (v_queue.floor_label=ANY(public.store_assignment_area_codes_v1(v_assignment)))')
print(bulk)
print('REVOKE ALL ON FUNCTION public.kds_apply_station_progress_batch_v1(uuid,uuid,uuid,text,text,jsonb) FROM PUBLIC,anon,authenticated;')
print('GRANT EXECUTE ON FUNCTION public.kds_record_station_progress_v3(uuid,text,text,integer,uuid),public.kds_serve_ready_order_v3(uuid,uuid) TO authenticated;')
PY
run_sql < "$scratch/baseline.sql" >/dev/null
run_sql < scripts/preflight_kds_partial_item_handoff.sql >/dev/null
run_sql < test/sql/kds_partial_item_handoff_before.sql
run_sql < supabase/migrations/20261022210000_kds_partial_item_handoff.sql >/dev/null
run_sql < scripts/verify_kds_partial_item_handoff.sql >/dev/null
run_sql < supabase/tests/kds_partial_item_handoff_test.sql
run_sql < supabase/tests/kds_explicit_kitchen_check_test.sql
python3 scripts/tests/kds_partial_item_handoff_concurrency.py "$fixture"
run_sql < scripts/rollback_kds_partial_item_handoff.sql >/dev/null
run_sql < test/sql/kds_partial_item_handoff_before.sql
run_sql < supabase/migrations/20261022210000_kds_partial_item_handoff.sql >/dev/null
run_sql < scripts/verify_kds_partial_item_handoff.sql >/dev/null
printf 'KDS_PARTIAL_ITEM_HANDOFF=PASS rollback_reapply=PASS network=none\n'
