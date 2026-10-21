#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
fixture_name="pos-direct-floor-live-$$"
fixture_tmp="$(mktemp -d)"
cleanup() { docker rm -f "$fixture_name" >/dev/null 2>&1 || true; rm -rf "$fixture_tmp"; }
trap cleanup EXIT
python3 - "$fixture_tmp/baseline.sql" <<'PY'
from pathlib import Path
import re,sys
base=Path('supabase/migrations/20260831010000_kds_realtime_v2.sql').read_text()
direct=Path('supabase/migrations/20261020090000_jeongabok_kitchen_floor.sql').read_text()
def function(s,name):
 m=re.search(r'CREATE (?:OR REPLACE )?FUNCTION (?:public\.|pg_temp\.)'+name+r'\(',s,re.I)
 return s[m.start():s.index('$$;',m.start())+3]+'\n'
out=''
for name in ['kds_realtime_rollouts','kds_store_revisions','kds_change_log']:
 a=base.index('CREATE TABLE IF NOT EXISTS public.'+name+' (')
 out+=base[a:base.index('\n);',a)+4]+'\n'
out+="ALTER TABLE public.kds_change_log DROP CONSTRAINT kds_change_log_floor_target; ALTER TABLE public.kds_change_log ADD CONSTRAINT kds_change_log_floor_target CHECK(target_floor_label IS NULL OR target_floor_label IN ('1F','2F','3F'));\n"
for name in ['kds_change_envelope','kds_append_change','kds_broadcast_change','get_kds_ticket_v2']:
 out+=function(base,name)
out+= 'ALTER FUNCTION public.get_kds_ticket_v2(uuid) RENAME TO get_kds_ticket_v2_pre_business_day;\n'
for name in ['kds_is_direct_floor_store','kds_direct_filter_targets','kds_direct_patch']:
 out+=function(direct,name)
capture=function(base,'kds_capture_fulfillment_event')
capture=capture.replace('  PERFORM public.kds_append_change(',"  v_payload := v_payload || jsonb_build_object('no_floor_delivery', v_delivery);\n  PERFORM public.kds_append_change(")
out+=capture
out+=re.search(r"SELECT pg_temp\.kds_direct_patch\('public\.kds_broadcast_change\(\)'[\s\S]+?\$new\$\);",direct).group()+'\n'
out+='CREATE TRIGGER kds_direct_filter_targets BEFORE INSERT OR UPDATE ON public.kds_change_log FOR EACH ROW EXECUTE FUNCTION public.kds_direct_filter_targets();\n'
out+='CREATE TRIGGER capture AFTER INSERT ON public.emergency_fulfillment_events FOR EACH ROW EXECUTE FUNCTION public.kds_capture_fulfillment_event();\n'
out+='CREATE CONSTRAINT TRIGGER broadcast AFTER INSERT ON public.kds_change_log DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.kds_broadcast_change();\n'
Path(sys.argv[1]).write_text(out)
PY
docker run --detach --rm --name "$fixture_name" --env POSTGRES_PASSWORD=floor-fixture --env POSTGRES_DB=floor_fixture public.ecr.aws/supabase/postgres:17.6.1.104 >/dev/null
for attempt in $(seq 1 60); do
 if docker exec "$fixture_name" pg_isready -h 127.0.0.1 -U postgres -d floor_fixture >/dev/null 2>&1; then break; fi
 if [[ "$attempt" == 60 ]]; then exit 1; fi
 sleep 1
done
run_sql() { docker exec -i --env PGPASSWORD=floor-fixture "$fixture_name" psql -X -v ON_ERROR_STOP=1 -U supabase_admin -d floor_fixture; }
run_sql < test/fixtures/jeongabok_floor_live_sync_setup.sql >/dev/null
run_sql < "$fixture_tmp/baseline.sql" >/dev/null
run_sql < test/sql/jeongabok_floor_live_sync_before.sql
run_sql < supabase/migrations/20261021100000_jeongabok_floor_live_sync.sql >/dev/null
run_sql < scripts/verify_jeongabok_floor_live_sync.sql
run_sql < test/sql/jeongabok_floor_live_sync_test.sql
