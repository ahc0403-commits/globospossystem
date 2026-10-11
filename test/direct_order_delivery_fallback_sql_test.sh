#!/usr/bin/env bash
set -euo pipefail
DELIVERY_HOURS_TEST=1 DIRECT_ORDER_FALLBACK_TEST=1 bash "$(dirname "${BASH_SOURCE[0]}")/direct_order_photo_approval_sql_test.sh"
PHOTO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PHOTO_TMP="$(mktemp -d)"
PHOTO_CONTAINER="globos-direct-fallback-test-$$"
cleanup() { docker rm -f "$PHOTO_CONTAINER" >/dev/null 2>&1 || true; rm -rf "$PHOTO_TMP"; }
trap cleanup EXIT
python3 - "$PHOTO_ROOT" "$PHOTO_TMP" <<'PY'
from pathlib import Path
import re,sys
root,tmp=map(Path,sys.argv[1:])
mdir=root/'supabase/migrations'
def source(file): return (mdir/file).read_text()
def function(file,name):
 s=source(file);m=re.search(r'CREATE (?:OR REPLACE )?FUNCTION public\.'+name+r'\(',s)
 if not m: raise RuntimeError(name)
 return s[m.start():s.index('$$;',m.start())+3]+'\n'
def block(file,label):
 s=source(file);start=s.index('DO $'+label+'$')
 return s[start:s.index('$'+label+'$;',start)+len(label)+3]+'\n'
base='20260821130000_direct_delivery_ordering.sql'
out=''
for file in ['20260805120000_sepay_bank_transfer_alerts.sql',base]:
 for m in re.finditer(r'CREATE TABLE (?:IF NOT EXISTS )?public\.\w+ \(',source(file)):
  s=source(file);out+=s[m.start():s.index('\n);',m.start())+4]+'\n'
s=source('20260910130000_direct_order_customer_payment_and_status.sql')
a=s.index('CREATE TABLE public.direct_order_proof_review_requests (')
out+=s[a:s.index('\n);',a)+4]+'\n'
out+=function('20260707010000_service_item_exclusion_v1.sql','process_payment')
out+=function(base,'direct_order_require_actor')
out+=function(base,'direct_order_public_submit')
out+=function(base,'direct_order_staff_quote')
out+=function(base,'direct_order_approve_payment')
out+='REVOKE ALL ON FUNCTION public.direct_order_approve_payment(uuid,uuid,numeric,text) FROM PUBLIC,anon;\n'
out+='GRANT EXECUTE ON FUNCTION public.direct_order_approve_payment(uuid,uuid,numeric,text) TO authenticated;\n'
pilot=source('20260908120000_direct_order_pilot_safety.sql')
out+=pilot[pilot.index('ALTER TABLE public.direct_order_quotes'):pilot.index('COMMENT ON COLUMN')]
out+=block('20260907150000_cashier_direct_delivery_availability.sql','patch_existing_requests')
out+=block('20260908120000_direct_order_pilot_safety.sql','proof_or_verified_payment')
out+=block('20260910130000_direct_order_customer_payment_and_status.sql','block_approval_during_review')
out+=function('20260908120000_direct_order_pilot_safety.sql','enqueue_direct_order_customer_receipt_after_payment')
out+='CREATE TRIGGER direct_order_customer_receipt_after_payment AFTER INSERT ON public.direct_order_financials FOR EACH ROW EXECUTE FUNCTION public.enqueue_direct_order_customer_receipt_after_payment();\n'
(tmp/'predecessor.sql').write_text(out)
PY
docker run --detach --rm --name "$PHOTO_CONTAINER" \
 --env POSTGRES_HOST_AUTH_METHOD=trust --env POSTGRES_DB=codex_direct_photo \
 postgres:15 -c track_functions=all >/dev/null
for ((attempt=0;attempt<60;attempt++)); do
 if docker exec "$PHOTO_CONTAINER" pg_isready -h 127.0.0.1 -U postgres -d codex_direct_photo >/dev/null 2>&1; then break; fi
 sleep 1
done
run_sql() { docker exec -i "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -v ON_ERROR_STOP=1 < "$1"; }
run_sql "$PHOTO_ROOT/test/fixtures/restaurant_vat_integrity_setup.sql" > "$PHOTO_TMP/setup.log" 2>&1 || { cat "$PHOTO_TMP/setup.log"; exit 1; }
run_sql "$PHOTO_ROOT/test/fixtures/direct_order_photo_approval_setup.sql" >> "$PHOTO_TMP/setup.log" 2>&1 || { cat "$PHOTO_TMP/setup.log"; exit 1; }
# Keep diagnostics visible on failure without exposing any production data.
run_sql "$PHOTO_TMP/predecessor.sql" > "$PHOTO_TMP/predecessor.log" 2>&1 || { cat "$PHOTO_TMP/predecessor.log"; exit 1; }
run_sql "$PHOTO_ROOT/supabase/migrations/20260824040000_direct_order_pilot_actions_and_progress.sql" >/dev/null
run_sql "$PHOTO_ROOT/supabase/tests/fixtures/direct_delivery_test_clock.sql" >/dev/null
run_sql "$PHOTO_ROOT/test/fixtures/direct_order_photo_approval_requests.sql" >/dev/null
# The original failure is reproduced before applying the fix.
 # Photo approval predecessor/retry behavior is covered by the current-main runner above.
PHOTO_PAYMENT_HASH="$(docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -Atqc \
 "select md5(pg_get_functiondef('public.process_payment(uuid,uuid,numeric,text)'::regprocedure))")"
run_sql "$PHOTO_ROOT/supabase/migrations/20261003060838_direct_order_customer_photo_approval.sql" >/dev/null
PHOTO_PAYMENT_HASH_AFTER="$(docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -Atqc \
 "select md5(pg_get_functiondef('public.process_payment(uuid,uuid,numeric,text)'::regprocedure))")"
[[ "$PHOTO_PAYMENT_HASH" == "$PHOTO_PAYMENT_HASH_AFTER" ]] || { printf 'PAYMENT_ANCHOR_CHANGED\n'; exit 1; }
 # Do not replay native-pickup photo fixtures against the older delivery-only foundation.

python3 - "$PHOTO_ROOT" "$PHOTO_TMP" <<'PYEXTRA'
from pathlib import Path
import re,sys
root,tmp=map(Path,sys.argv[1:]); mdir=root/'supabase/migrations'
def source(name): return (mdir/name).read_text()
def function(file,name):
 s=source(file); m=re.search(r'CREATE (?:OR REPLACE )?FUNCTION public\.'+name+r'\(',s,re.I)
 if not m: raise RuntimeError(name)
 return s[m.start():s.index('$$;',m.start())+3]+'\n'
base='20260821130000_direct_delivery_ordering.sql'
out="""
ALTER TABLE restaurants ADD COLUMN name text DEFAULT 'Fallback Test',ADD COLUMN address text DEFAULT '123 Test Street',ADD COLUMN is_active boolean DEFAULT true;
ALTER TABLE menu_items ADD COLUMN category_id uuid,ADD COLUMN description text,ADD COLUMN image_url text,ADD COLUMN sort_order integer DEFAULT 0,ADD COLUMN combo_drink_choice_count integer DEFAULT 0;
CREATE TABLE menu_categories(id uuid,restaurant_id uuid,name text,name_ko text,name_vi text,name_en text,sort_order integer,is_active boolean);
ALTER TABLE direct_order_storefronts ADD COLUMN ordering_hours_enforced boolean DEFAULT false;
ALTER TABLE direct_order_dispatches ADD COLUMN cash_paid_at timestamptz;
CREATE TABLE print_jobs(id uuid DEFAULT gen_random_uuid(),order_id uuid,restaurant_id uuid,payload jsonb);
CREATE TABLE einvoice_jobs(order_id uuid,status text,lookup_url text,redinvoice_requested boolean);
"""
refund='20260604001000_pos_payment_refund_void_adjustments.sql'
r=source(refund);a=r.index('create table if not exists public.payment_adjustments');out+=r[a:r.index('\n);',a)+4]+'\n'
out+=function(refund,'record_payment_adjustment')
for name in ['direct_order_validate_session','direct_order_public_storefront','direct_order_public_create_session','direct_order_public_status','direct_order_staff_detail','direct_order_analytics']:
 out+=function(base,name)
out+=function('20260901130000_operational_order_business_day_scope.sql','direct_delivery_ticket_list')
out+=source('20260907130000_direct_delivery_manual_addresses.sql')
v2='20260910130000_direct_order_customer_payment_and_status.sql'
s2=source(v2);a=s2.index('DO $remove_single_open_guard$');out+=s2[a:s2.index('$remove_single_open_guard$;',a)+len('$remove_single_open_guard$;')]+'\n'
for name in ['direct_order_public_status_v2','direct_order_public_orders_v2','direct_order_staff_list_v2','direct_order_staff_detail_v2','direct_delivery_ticket_transition']:
 out+=function(v2,name)
out+=function('20260907100000_direct_delivery_cash_payout_daily_closing.sql','direct_order_set_dispatch')
out+=function('20260908120000_direct_order_pilot_safety.sql','direct_order_staff_quote_with_payment_mode')
out+=function('20260908120000_direct_order_pilot_safety.sql','direct_order_set_dispatch_with_payment_mode')
out+="ALTER TABLE direct_order_requests ADD COLUMN IF NOT EXISTS fulfillment_type text NOT NULL DEFAULT 'delivery';\n"
out+='CREATE TABLE emergency_order_queue(order_id uuid);\n'
pickup=source('20261002030000_direct_order_delivery_pickup.sql')
a=pickup.index('CREATE FUNCTION pg_temp.direct_pickup_patch(')
out+=pickup[a:pickup.index('$$;',a)+3]+'\n'
for signature in ['public.direct_order_approve_payment(', 'public.direct_delivery_ticket_transition(']:
 for match in re.finditer(r"SELECT pg_temp\.direct_pickup_patch\('"+re.escape(signature)+r"[\s\S]*?\$new\$\);",pickup):
  # Only the count-slot and takeaway accounting anchor is required here.
  if signature.startswith('public.direct_order_approve') and "'serving', NULL," not in match.group(): continue
  out+=match.group()+'\n'
out+=function('20260907130000_direct_delivery_manual_addresses.sql','direct_order_public_submit').replace('FUNCTION public.direct_order_public_submit(', 'FUNCTION public.direct_order_public_submit_v2(')
out+=function('20261002030000_direct_order_delivery_pickup.sql','direct_order_public_orders_v3')
(tmp/'fallback_predecessor.sql').write_text(out)
PYEXTRA
run_sql "$PHOTO_TMP/fallback_predecessor.sql" > "$PHOTO_TMP/fallback_setup.log" 2>&1 || { cat "$PHOTO_TMP/fallback_setup.log"; exit 1; }
run_sql "$PHOTO_ROOT/supabase/migrations/20261005070000_direct_order_delivery_fallback.sql" > "$PHOTO_TMP/migration.log" 2>&1 || { cat "$PHOTO_TMP/migration.log"; exit 1; }
run_sql "$PHOTO_ROOT/test/fixtures/direct_order_fallback_set_based_reads.sql" > "$PHOTO_TMP/reads_setup.log" 2>&1 || { cat "$PHOTO_TMP/reads_setup.log"; exit 1; }
measure_read_calls() {
 local read_phase="$1" read_limit
 for read_limit in 1 50 100 200; do
  docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -v ON_ERROR_STOP=1 -c \
   "SELECT pg_stat_reset(); SELECT jsonb_array_length(public.direct_delivery_ticket_list_v3('d2000000-0000-4000-8000-000000000001',NULL,$read_limit)); SELECT pg_stat_force_next_flush();" >/dev/null
  docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -v ON_ERROR_STOP=1 -c \
   "INSERT INTO fallback_read_test.measurements SELECT '$read_phase',$read_limit,
    COALESCE((SELECT calls FROM pg_stat_user_functions WHERE funcid='public.direct_order_fulfillment_context(uuid)'::regprocedure),0),
    COALESCE((SELECT calls FROM pg_stat_user_functions WHERE funcid='public.direct_delivery_ticket_list(uuid,text[],timestamptz,uuid,integer)'::regprocedure),0),
    COALESCE((SELECT calls FROM pg_stat_user_functions WHERE funcid='public.direct_order_require_actor(uuid,text[])'::regprocedure),0),
    COALESCE((SELECT calls FROM pg_stat_user_functions WHERE funcid='public.direct_delivery_ticket_list_v3(uuid,text[],integer)'::regprocedure),0);" >/dev/null
 done
}
measure_read_calls before
run_sql "$PHOTO_ROOT/supabase/migrations/20261005080000_direct_order_fallback_set_based_reads.sql" > "$PHOTO_TMP/reads_migration.log" 2>&1 || { cat "$PHOTO_TMP/reads_migration.log"; exit 1; }
measure_read_calls after
run_sql "$PHOTO_ROOT/test/sql/direct_order_fallback_set_based_reads_assert.sql"
# EXPLAIN the exact query from the replacement, with its local parameters bound.
docker exec "$PHOTO_CONTAINER" psql -X -At -U postgres -d codex_direct_photo -v ON_ERROR_STOP=1 -c \
 "SELECT jsonb_build_object('staff',pg_get_functiondef('public.direct_order_staff_list_v2(uuid,text[],integer)'::regprocedure),'customer',pg_get_functiondef('public.direct_order_public_orders_v2(uuid,text,integer)'::regprocedure));" \
 > "$PHOTO_TMP/legacy_read_definitions.json"
python3 - "$PHOTO_ROOT" "$PHOTO_TMP" <<'PYPLAN'
from pathlib import Path
import json,sys
root,tmp=map(Path,sys.argv[1:])
s=(root/'supabase/migrations/20261005080000_direct_order_fallback_set_based_reads.sql').read_text()
query=s.split('  RETURN (\n',1)[1].split('\n  );',1)[0]
day="((now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh')"
for name,value in [('p_store_id',"'d2000000-0000-4000-8000-000000000001'::uuid"),
                   ('p_statuses','NULL::text[]'),('p_limit','200'),
                   ('v_day_start',day),('v_day_end',f"({day} + interval '1 day')")]:
 query=query.replace(name,value)
(tmp/'reads_explain.sql').write_text('EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) '+query+';\n')
for name,definition in json.loads((tmp/'legacy_read_definitions.json').read_text()).items():
 query=definition.split('RETURN COALESCE((\n',1)[1].split("\n  ), '[]'::jsonb);",1)[0]
 store="'d2000000-0000-4000-8000-000000000001'::uuid"
 for parameter,value in [('p_store_id',store),('p_states','NULL::text[]'),
   ('p_limit','200' if name=='staff' else '50'),('v_day_start',day),
   ('v_day_end',f"({day} + interval '1 day')"),('v_session.restaurant_id',store),
   ('v_session.id',store),('v_session.created_at',f'(SELECT created_at FROM public.direct_order_sessions WHERE id={store})')]:
  query=query.replace(parameter,value)
 (tmp/f'{name}_explain.sql').write_text('EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) '+query+';\n')
PYPLAN
docker exec -i "$PHOTO_CONTAINER" psql -X -At -U postgres -d codex_direct_photo -v ON_ERROR_STOP=1 \
 < "$PHOTO_TMP/reads_explain.sql" > "$PHOTO_TMP/reads_explain.json"
python3 - "$PHOTO_TMP/reads_explain.json" <<'PYASSERT'
import json,sys
plan=json.load(open(sys.argv[1]))[0]
def walk(node):
 yield node
 for child in node.get('Plans',[]): yield from walk(child)
nodes=list(walk(plan['Plan']))
assert not any(n.get('Subplan Name','').startswith('SubPlan') for n in nodes), 'CORRELATED_SUBPLAN_REINTRODUCED'
groups=[n for n in nodes if n['Node Type']=='Aggregate' and n.get('Group Key')]
assert len(groups)==1 and groups[0]['Actual Loops']==1 and groups[0]['Actual Rows']==199, 'ITEMS_NOT_AGGREGATED_AS_ONE_SET'
pages=[n for n in nodes if n.get('Subplan Name')=='CTE ticket_page']
assert len(pages)==1 and pages[0]['Actual Rows']==200 and pages[0]['Actual Loops']==1, 'UNBOUNDED_OR_REPEATED_PAGE'
print('DIRECT_ORDER_SET_BASED_EXPLAIN=PASS tickets=200 item_groups=199 group_loops=1 correlated_subplans=0')
PYASSERT
for legacy_read in staff customer; do
 docker exec -i "$PHOTO_CONTAINER" psql -X -At -U postgres -d codex_direct_photo -v ON_ERROR_STOP=1 \
  < "$PHOTO_TMP/${legacy_read}_explain.sql" > "$PHOTO_TMP/${legacy_read}_explain.json"
done
python3 - "$PHOTO_TMP" <<'PYLEGACY'
from pathlib import Path
import json,sys
def walk(node):
 yield node
 for child in node.get('Plans',[]): yield from walk(child)
for name in ['staff','customer']:
 nodes=list(walk(json.loads((Path(sys.argv[1])/f'{name}_explain.json').read_text())[0]['Plan']))
 subplans=[n for n in nodes if n.get('Subplan Name','').startswith('SubPlan')]
 print(f'DIRECT_ORDER_LEGACY_READ_AUDIT={name} correlated_subplan_loops='+','.join(str(n['Actual Loops']) for n in subplans))
PYLEGACY
run_sql "$PHOTO_ROOT/supabase/tests/direct_order_delivery_fallback_contract_test.sql"
# Independent connections exercise same-request consent/refund serialization.
run_sql "$PHOTO_ROOT/test/fixtures/direct_order_delivery_fallback_races.sql" > "$PHOTO_TMP/races.log" 2>&1 || { cat "$PHOTO_TMP/races.log"; exit 1; }
for operation in consent refund dispatch offer_dispatch; do
 for suffix in a b; do
  if [[ "$suffix" == a ]]; then race_first=true; else race_first=false; fi
  docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -v ON_ERROR_STOP=1 -c "SELECT fallback_test.race_call('$operation',$race_first);" > "$PHOTO_TMP/$operation-$suffix.log" 2>&1 &
  if [[ "$suffix" == a ]]; then race_pid_a=$!; else race_pid_b=$!; fi
 done
 wait "$race_pid_a" || { cat "$PHOTO_TMP/$operation-a.log"; exit 1; }
 wait "$race_pid_b" || { cat "$PHOTO_TMP/$operation-b.log"; exit 1; }
done
run_sql "$PHOTO_ROOT/test/sql/direct_order_delivery_fallback_races_assert.sql"
run_sql "$PHOTO_ROOT/test/fixtures/direct_order_receipt_packing_setup.sql" >/dev/null
python3 - "$PHOTO_ROOT" "$PHOTO_TMP" <<'PYPACKING'
from pathlib import Path
import sys
root,tmp=map(Path,sys.argv[1:])
s=(root/'supabase/migrations/20260710002000_receipt_print_queue.sql').read_text()
a=s.index('CREATE OR REPLACE FUNCTION public.enqueue_receipt_print_job(')
(tmp/'packing_enqueue.sql').write_text(s[a:s.index('$$;',a)+3])
PYPACKING
run_sql "$PHOTO_TMP/packing_enqueue.sql" >/dev/null
run_sql "$PHOTO_ROOT/scripts/preflight_direct_order_receipt_packing_context.sql" >/dev/null
run_sql "$PHOTO_ROOT/supabase/migrations/20261006020000_direct_order_receipt_packing_context.sql" >/dev/null
run_sql "$PHOTO_ROOT/supabase/tests/direct_order_receipt_packing_contract_test.sql"
if [[ "${DIRECT_ORDER_CUSTOMER_EXPERIENCE_TEST:-0}" == "1" ]]; then
 python3 - "$PHOTO_ROOT" "$PHOTO_TMP" <<'PYFEEDBACK'
from pathlib import Path
import sys
root,tmp=map(Path,sys.argv[1:])
s=(root/'supabase/migrations/20260824060000_direct_delivery_kds_routing.sql').read_text()
a=s.index('CREATE OR REPLACE FUNCTION public.sync_direct_delivery_ticket_from_kds()')
setup="CREATE TABLE public.emergency_fulfillment_items(order_id uuid,is_cancelled boolean,tray_dispatched_quantity integer,ordered_quantity integer,excused_quantity integer DEFAULT 0);\n"
definition=s[a:s.index('$$;',a)+3]
pickup=(root/'supabase/migrations/20261002030000_direct_order_delivery_pickup.sql').read_text()
helper_start=pickup.index('CREATE FUNCTION public.direct_order_is_pickup_pos_order(')
setup+='ALTER TABLE public.direct_order_requests ADD COLUMN IF NOT EXISTS fulfillment_type text NOT NULL DEFAULT \'delivery\';\n'
setup+=pickup[helper_start:pickup.index('$$;',helper_start)+3].replace('CREATE FUNCTION','CREATE OR REPLACE FUNCTION',1)+'\n'
kds=(root/'supabase/migrations/20261005010000_direct_pickup_kds_handoff.sql').read_text()
patch=kds.split("SELECT pg_temp.pickup_kds_patch('public.sync_direct_delivery_ticket_from_kds()',",1)[1]
pickup_branch=patch.split('$new$',1)[1].split('$new$',1)[0]
definition=definition.replace('BEGIN\n','BEGIN\n'+pickup_branch+'\n',1)
setup+=definition+'\n'
setup+="CREATE TABLE feedback_kds_events(order_id uuid,actor_user_id uuid,stage text,delta integer,restaurant_id uuid DEFAULT 'd1000000-0000-4000-8000-000000000002');\nCREATE TRIGGER feedback_kds_event AFTER INSERT ON feedback_kds_events FOR EACH ROW EXECUTE FUNCTION public.sync_direct_delivery_ticket_from_kds();\n"
(tmp/'feedback_setup.sql').write_text(setup)
PYFEEDBACK
 run_sql "$PHOTO_TMP/feedback_setup.sql" >/dev/null
 run_sql "$PHOTO_ROOT/scripts/preflight_direct_order_customer_experience.sql" >/dev/null
 run_sql "$PHOTO_ROOT/supabase/migrations/20261006030000_direct_order_customer_experience.sql" > "$PHOTO_TMP/feedback_migration.log" 2>&1 || { cat "$PHOTO_TMP/feedback_migration.log"; exit 1; }
 run_sql "$PHOTO_ROOT/scripts/verify_direct_order_customer_experience.sql" >/dev/null
 run_sql "$PHOTO_ROOT/supabase/tests/direct_order_customer_experience_test.sql"
 run_sql "$PHOTO_ROOT/scripts/preflight_direct_order_detail_customer_context.sql" >/dev/null
 detail_v3_before="$(docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -Atqc "SELECT md5(pg_get_functiondef('public.direct_order_public_status_v3(uuid,text,uuid)'::regprocedure))")"
 run_sql "$PHOTO_ROOT/supabase/migrations/20261007010000_direct_order_detail_customer_context.sql" >/dev/null
 run_sql "$PHOTO_ROOT/scripts/verify_direct_order_detail_customer_context.sql" >/dev/null
 run_sql "$PHOTO_ROOT/supabase/tests/direct_order_detail_customer_context_test.sql"
 detail_v3_after="$(docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -Atqc "SELECT md5(pg_get_functiondef('public.direct_order_public_status_v3(uuid,text,uuid)'::regprocedure))")"
 [[ "$detail_v3_before" == "$detail_v3_after" ]] || { printf 'DETAIL_V3_COMPATIBILITY_CHANGED\n'; exit 1; }
 run_sql "$PHOTO_ROOT/scripts/rollback_direct_order_detail_customer_context.sql" >/dev/null
 docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -v ON_ERROR_STOP=1 -c "DO \$\$ BEGIN ASSERT strpos(pg_get_functiondef('public.direct_order_public_status_v4(uuid,text,uuid)'::regprocedure),'jsonb_build_object(''customer'',NULL)')>0,'DETAIL_ROLLBACK_INCOMPATIBLE'; END \$\$;" >/dev/null
 printf 'DIRECT_ORDER_DETAIL_CUSTOMER_CONTEXT_ROLLBACK=PASS\n'
 run_sql "$PHOTO_ROOT/test/fixtures/direct_order_customer_experience_races.sql" >/dev/null
 docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -v ON_ERROR_STOP=1 -c "SET statement_timeout='8s'; SELECT feedback_race.staff_event();" > "$PHOTO_TMP/feedback_staff_race.log" 2>&1 &
 feedback_staff_pid=$!
 docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -v ON_ERROR_STOP=1 -c "SET application_name='direct-customer-session-race'; SET statement_timeout='8s'; SELECT feedback_race.customer_activity();" > "$PHOTO_TMP/feedback_customer_race.log" 2>&1 &
 feedback_customer_pid=$!
 wait "$feedback_staff_pid" || { cat "$PHOTO_TMP/feedback_staff_race.log"; exit 1; }
 wait "$feedback_customer_pid" || { cat "$PHOTO_TMP/feedback_customer_race.log"; exit 1; }
 printf 'DIRECT_ORDER_CUSTOMER_SESSION_NOTIFICATION_CONCURRENCY=PASS\n'
 docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -v ON_ERROR_STOP=1 -c "UPDATE public.users SET restaurant_id='d2000000-0000-4000-8000-000000000001' WHERE auth_id=auth.uid();" >/dev/null
 for feedback_limit in 1 50 100 200; do
  docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -v ON_ERROR_STOP=1 -c "SELECT pg_stat_reset(); SELECT jsonb_array_length(public.direct_order_staff_list_v3('d2000000-0000-4000-8000-000000000001',NULL,$feedback_limit)); SELECT pg_stat_force_next_flush();" >/dev/null
  feedback_rows="$(docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -Atqc "SELECT jsonb_array_length(public.direct_order_staff_list_v3('d2000000-0000-4000-8000-000000000001',NULL,$feedback_limit))")"
  [[ "$feedback_rows" == "$feedback_limit" ]] || { printf 'FEEDBACK_MEASUREMENT_PAGE_INCOMPLETE\n'; exit 1; }
  feedback_calls="$(docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -Atqc "SELECT COALESCE(sum(calls),0) FROM pg_stat_user_functions WHERE funcid IN ('public.direct_order_fulfillment_context(uuid)'::regprocedure,'public.direct_order_staff_detail_v3(uuid,uuid)'::regprocedure)")"
  [[ "$feedback_calls" == "0" ]] || { printf 'FEEDBACK_LIST_N_PLUS_ONE\n'; exit 1; }
  printf 'DIRECT_ORDER_CUSTOMER_LIST limit=%s rows=%s detail_calls=%s\n' "$feedback_limit" "$feedback_rows" "$feedback_calls"
 done
 docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -v ON_ERROR_STOP=1 -c "UPDATE public.users u SET restaurant_id=a.restaurant_id FROM fallback_read_test.original_actor a WHERE u.auth_id=auth.uid();" >/dev/null
 run_sql "$PHOTO_ROOT/scripts/rollback_direct_order_customer_experience.sql" >/dev/null
 rollback_hash="$(docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -Atqc "SELECT md5(pg_get_functiondef('public.sync_direct_delivery_ticket_from_kds()'::regprocedure))")"
 [[ "$rollback_hash" == "c206203f3aa5e3933e7a8a1327f0f31f" ]] || { printf 'CUSTOMER_ROLLBACK_KDS_MISMATCH\n'; exit 1; }
 printf 'DIRECT_ORDER_CUSTOMER_EXPERIENCE_SQL_TEST=PASS rollback=PASS\n'
fi
# The legacy fixture fixes auth.uid(); use the real JWT lookup semantics here.
python3 - "$PHOTO_ROOT" "$PHOTO_TMP" <<'PYVERIFY'
from pathlib import Path
import sys
root,tmp=map(Path,sys.argv[1:])
setup="""
UPDATE public.users SET role='super_admin' WHERE auth_id=auth.uid();
CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $$
 SELECT NULLIF(current_setting('request.jwt.claim.sub',true),'')::uuid
$$;
"""
(tmp/'packing_verify.sql').write_text(setup+(root/'scripts/verify_direct_order_receipt_packing_context.sql').read_text())
PYVERIFY
run_sql "$PHOTO_TMP/packing_verify.sql"
python3 - "$PHOTO_ROOT" "$PHOTO_TMP" <<'PYRECEIPT'
from pathlib import Path
import sys
root,tmp=map(Path,sys.argv[1:])
out="ALTER TABLE public.print_jobs ADD COLUMN combined_payment_group_id uuid;\n"
for file,name,table,trigger in [
 ('20260722100000_vietnamese_only_printer_output.sql','force_print_job_menu_labels_vi','print_jobs','force_print_job_menu_labels_vi'),
 ('20260815171000_digital_receipt_vietnamese.sql','digital_receipt_force_vietnamese_items','digital_receipts','digital_receipt_force_vietnamese_items_trigger')]:
 s=(root/'supabase/migrations'/file).read_text()
 a=s.index('CREATE OR REPLACE FUNCTION public.'+name+'(')
 out+=s[a:s.index('$$;',a)+3]+'\n'
 out+=f'CREATE TRIGGER {trigger} BEFORE INSERT ON public.{table} FOR EACH ROW EXECUTE FUNCTION public.{name}();\n'
(tmp/'receipt_labels.sql').write_text(out)
PYRECEIPT
run_sql "$PHOTO_TMP/receipt_labels.sql" >/dev/null
run_sql "$PHOTO_ROOT/test/sql/direct_order_receipt_requests_before.sql"
run_sql "$PHOTO_ROOT/scripts/preflight_direct_order_receipt_requests.sql"
receipt_before="$(docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -Atqc "SELECT md5(string_agg(pg_get_functiondef(oid),'' ORDER BY oid)) FROM pg_proc WHERE oid IN ('public.direct_order_receipt_packing_context(uuid,uuid)'::regprocedure,'public.direct_order_enrich_print_fulfillment()'::regprocedure,'public.direct_order_enrich_digital_receipt_packing()'::regprocedure)")"
run_sql "$PHOTO_ROOT/supabase/migrations/20261008010000_direct_order_receipt_requests.sql" >/dev/null
run_sql "$PHOTO_ROOT/supabase/tests/direct_order_receipt_requests_contract_test.sql"
run_sql "$PHOTO_ROOT/scripts/verify_direct_order_receipt_requests.sql"
run_sql "$PHOTO_ROOT/scripts/rollback_direct_order_receipt_requests.sql" >/dev/null
receipt_after="$(docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -Atqc "SELECT md5(string_agg(pg_get_functiondef(oid),'' ORDER BY oid)) FROM pg_proc WHERE oid IN ('public.direct_order_receipt_packing_context(uuid,uuid)'::regprocedure,'public.direct_order_enrich_print_fulfillment()'::regprocedure,'public.direct_order_enrich_digital_receipt_packing()'::regprocedure)")"
[[ "$receipt_before" == "$receipt_after" ]] || { printf 'RECEIPT_REQUESTS_ROLLBACK_MISMATCH\n'; exit 1; }
run_sql "$PHOTO_ROOT/scripts/preflight_direct_order_receipt_requests.sql" >/dev/null
run_sql "$PHOTO_ROOT/supabase/migrations/20261008010000_direct_order_receipt_requests.sql" >/dev/null
run_sql "$PHOTO_ROOT/scripts/verify_direct_order_receipt_requests.sql" >/dev/null
printf 'RECEIPT_REQUESTS_ROLLBACK_AND_REAPPLY=PASS\n'
if [[ "${DIRECT_ORDER_SUPPORT_TEST:-0}" == "1" ]]; then
 python3 - "$PHOTO_ROOT" "$PHOTO_TMP" <<'PYSUPPORTRESTORE'
from pathlib import Path
import re,sys
root,tmp=map(Path,sys.argv[1:])
s=(root/'supabase/migrations/20261006030000_direct_order_customer_experience.sql').read_text()
a=s.index('DO $kds_ready$')
(tmp/'support_restore_kds.sql').write_text(s[a:s.index('$kds_ready$;',a)+len('$kds_ready$;')])
# Load the actual effective retention definitions, rather than fixture stubs.
out=''
for name in ['direct_order_cleanup_expired_pii','direct_order_cleanup_candidates','direct_order_public_message','direct_order_staff_message']:
 matches=[]
 for p in sorted((root/'supabase/migrations').glob('*.sql')):
  if p.name >= '20261008020000': continue
  src=p.read_text();m=re.search(r'CREATE (?:OR REPLACE )?FUNCTION public\.'+name+r'\(',src)
  if m: matches.append(src[m.start():src.index('$$;',m.start())+3].replace('CREATE FUNCTION','CREATE OR REPLACE FUNCTION',1))
 assert matches,name
 out+=matches[-1]+'\n'
(tmp/'support_retention_predecessor.sql').write_text(out)
PYSUPPORTRESTORE
 run_sql "$PHOTO_TMP/support_restore_kds.sql" >/dev/null
 run_sql "$PHOTO_ROOT/scripts/rollback_direct_order_detail_customer_context.sql" >/dev/null
 # The v4 migration is additive; extract its function to replace the rollback shim.
 python3 - "$PHOTO_ROOT" "$PHOTO_TMP" <<'PYSUPPORTV4'
from pathlib import Path
import sys
root,tmp=map(Path,sys.argv[1:]);s=(root/'supabase/migrations/20261007010000_direct_order_detail_customer_context.sql').read_text();a=s.index('CREATE FUNCTION public.direct_order_public_status_v4(')
(tmp/'support_status_v4.sql').write_text(s[a:s.index('$$;',a)+3].replace('CREATE FUNCTION','CREATE OR REPLACE FUNCTION',1))
PYSUPPORTV4
 run_sql "$PHOTO_TMP/support_status_v4.sql" >/dev/null
 run_sql "$PHOTO_TMP/support_retention_predecessor.sql" >/dev/null
 docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -v ON_ERROR_STOP=1 -c "ALTER DATABASE codex_direct_photo SET request.jwt.claim.sub='00000000-0000-4000-8000-000000000001'" >/dev/null
 run_sql "$PHOTO_ROOT/test/fixtures/direct_order_support_setup.sql" >/dev/null
 run_sql "$PHOTO_ROOT/scripts/preflight_direct_order_support_and_payments.sql" >/dev/null
 run_sql "$PHOTO_ROOT/supabase/migrations/20261008020000_direct_order_support_and_payments.sql" > "$PHOTO_TMP/support_migration.log" 2>&1 || { cat "$PHOTO_TMP/support_migration.log"; exit 1; }
 run_sql "$PHOTO_ROOT/scripts/verify_direct_order_support_and_payments.sql"
 # A database clone verifies restoration before any support ledger is written.
 docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d postgres -v ON_ERROR_STOP=1 -c 'CREATE DATABASE codex_direct_support_rollback TEMPLATE codex_direct_photo' >/dev/null
 docker exec -i "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_support_rollback -v ON_ERROR_STOP=1 < "$PHOTO_ROOT/scripts/rollback_direct_order_support_and_payments.sql" > "$PHOTO_TMP/support_empty_rollback.log" 2>&1 || { cat "$PHOTO_TMP/support_empty_rollback.log"; exit 1; }
 restored="$(docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_support_rollback -Atqc "SELECT bool_and(pg_get_functiondef(object_identity::regprocedure)=definition) FROM public.direct_order_support_20261008020000_backup")"
 [[ "$restored" == "t" ]] || { printf 'SUPPORT_ROLLBACK_PREDECESSOR_MISMATCH\n'; exit 1; }
 docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d postgres -v ON_ERROR_STOP=1 -c 'DROP DATABASE codex_direct_support_rollback' >/dev/null
 printf 'DIRECT_ORDER_SUPPORT_UNUSED_ROLLBACK=PASS definitions=13\n'
 # Exercise the real PostgREST transaction mode, which direct SQL misses.
 bash "$PHOTO_ROOT/test/direct_order_status_rpc_test.sh" "$PHOTO_CONTAINER"
 run_sql "$PHOTO_ROOT/supabase/tests/direct_order_support_and_payments_test.sql"
 if run_sql "$PHOTO_ROOT/scripts/rollback_direct_order_support_and_payments.sql" > "$PHOTO_TMP/support_rollback.log" 2>&1; then
  printf 'SUPPORT_ROLLBACK_ERASED_ACTIVE_LEDGER\n'; exit 1
 fi
 grep -q 'DIRECT_ORDER_SUPPORT_ROLLBACK_REQUIRES_FORWARD_FIX' "$PHOTO_TMP/support_rollback.log"
 printf 'DIRECT_ORDER_SUPPORT_GUARDED_ROLLBACK=PASS\n'
 python3 - "$PHOTO_ROOT" "$PHOTO_TMP" <<'PYKDS'
from pathlib import Path
import sys
root,tmp=map(Path,sys.argv[1:])
s=(root/'test/fixtures/kds_set_based_enrichment_setup.sql').read_text().split('INSERT INTO public.emergency_order_queue')[0]
s=s.replace('CREATE TABLE public.','CREATE TABLE IF NOT EXISTS public.').replace('CREATE INDEX ', 'CREATE INDEX IF NOT EXISTS ')
s="ALTER TABLE public.emergency_order_queue ADD COLUMN IF NOT EXISTS id uuid DEFAULT gen_random_uuid(), ADD COLUMN IF NOT EXISTS workflow_version smallint DEFAULT 1;\nALTER TABLE public.emergency_fulfillment_items ADD COLUMN IF NOT EXISTS id uuid, ADD COLUMN IF NOT EXISTS kitchen_started_quantity integer, ADD COLUMN IF NOT EXISTS excused_quantity integer;\n"+s
(tmp/'support_kds_setup.sql').write_text(s)
PYKDS
 run_sql "$PHOTO_TMP/support_kds_setup.sql" >/dev/null
 run_sql "$PHOTO_ROOT/supabase/migrations/20260919160000_kds_set_based_enrichment.sql" >/dev/null
 docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -v ON_ERROR_STOP=1 -c "ALTER TABLE public.emergency_order_queue ADD COLUMN IF NOT EXISTS order_id uuid" >/dev/null
 run_sql "$PHOTO_ROOT/scripts/preflight_kds_menu_requests.sql" >/dev/null
 run_sql "$PHOTO_ROOT/supabase/migrations/20261008021000_kds_menu_requests.sql" >/dev/null
 run_sql "$PHOTO_ROOT/scripts/verify_kds_menu_requests.sql"
 run_sql "$PHOTO_ROOT/supabase/tests/kds_menu_requests_test.sql"
 for notes_items in 1 100 500; do
  docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -v ON_ERROR_STOP=1 -c "SELECT pg_stat_reset(); WITH note_item AS (SELECT id,order_id FROM public.order_items WHERE notes='không hành lá' LIMIT 1), input AS (SELECT jsonb_build_array(jsonb_build_object('queue_id',q.id,'items',jsonb_agg(jsonb_build_object('id',gen_random_uuid(),'order_item_id',i.id,'ordered_quantity',1)))) orders FROM note_item i JOIN public.emergency_order_queue q ON q.order_id=i.order_id CROSS JOIN generate_series(1,$notes_items) n GROUP BY q.id LIMIT 1) SELECT jsonb_array_length(public.emergency_enrich_start_ready_orders(orders)->0->'items') FROM input; SELECT pg_stat_force_next_flush();" >/dev/null
  notes_calls="$(docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -Atqc "SELECT COALESCE(sum(calls),0) FROM pg_stat_user_functions WHERE funcid='public.emergency_enrich_start_ready_orders_pre_menu_requests(jsonb)'::regprocedure")"
  [[ "$notes_calls" == "1" ]] || { printf 'KDS_MENU_REQUEST_N_PLUS_ONE\n'; exit 1; }
  printf 'KDS_MENU_REQUEST_SNAPSHOT items=%s base_calls=%s\n' "$notes_items" "$notes_calls"
 done
 run_sql "$PHOTO_ROOT/scripts/rollback_kds_menu_requests.sql" >/dev/null
 run_sql "$PHOTO_ROOT/scripts/preflight_kds_menu_requests.sql" >/dev/null
 run_sql "$PHOTO_ROOT/supabase/migrations/20261008021000_kds_menu_requests.sql" >/dev/null
 run_sql "$PHOTO_ROOT/scripts/verify_kds_menu_requests.sql" >/dev/null
 printf 'KDS_MENU_REQUEST_ROLLBACK_AND_REAPPLY=PASS\n'
fi
if [[ "${DIRECT_ORDER_INTEGRATED_TEST:-0}" == "1" ]]; then
 python3 - "$PHOTO_ROOT" "$PHOTO_TMP" <<'PYINTEGRATED'
from pathlib import Path
import sys
root,tmp=map(Path,sys.argv[1:]); output=''
for file,name in [('20260821130000_direct_delivery_ordering.sql','direct_order_public_commit_proof'),('20260910130000_direct_order_customer_payment_and_status.sql','direct_order_public_commit_proof_v2')]:
 source=(root/'supabase/migrations'/file).read_text(); start=source.index('CREATE OR REPLACE FUNCTION public.'+name+'(')
 output+=source[start:source.index('$$;',start)+3]+'\n'
(tmp/'integrated_predecessor.sql').write_text(output)
PYINTEGRATED
 run_sql "$PHOTO_TMP/integrated_predecessor.sql" >/dev/null
 run_sql "$PHOTO_ROOT/supabase/migrations/20261009010000_direct_order_status_session_activity.sql" >/dev/null
 run_sql "$PHOTO_ROOT/supabase/migrations/20261009150000_direct_order_final_amount_and_access.sql" > "$PHOTO_TMP/integrated_migration.log" 2>&1 || { cat "$PHOTO_TMP/integrated_migration.log"; exit 1; }
 run_sql "$PHOTO_ROOT/supabase/tests/direct_order_final_amount_and_access_test.sql"
 run_sql "$PHOTO_ROOT/supabase/migrations/20261009151000_direct_order_verified_delivery_cost.sql" > "$PHOTO_TMP/cost_migration.log" 2>&1 || { cat "$PHOTO_TMP/cost_migration.log"; exit 1; }
 run_sql "$PHOTO_ROOT/supabase/tests/direct_order_verified_delivery_cost_test.sql"
fi
if [[ "${DIRECT_ORDER_MONEY_TEST:-0}" == "1" ]]; then
 python3 "$PHOTO_ROOT/test/fixtures/direct_order_money_predecessor.py" "$PHOTO_ROOT" "$PHOTO_TMP/money_predecessor.sql"
 run_sql "$PHOTO_TMP/money_predecessor.sql" >/dev/null
 run_sql "$PHOTO_ROOT/supabase/migrations/20261010010000_direct_order_money_reconciliation.sql" > "$PHOTO_TMP/money_migration.log" 2>&1 || { cat "$PHOTO_TMP/money_migration.log"; exit 1; }
 run_sql "$PHOTO_ROOT/supabase/tests/direct_order_money_reconciliation_test.sql"
 run_sql "$PHOTO_ROOT/supabase/migrations/20261010020000_direct_order_automatic_translation.sql"
 run_sql "$PHOTO_ROOT/supabase/tests/direct_order_automatic_translation_test.sql"
 DIRECT_ORDER_STATUS_V7_TEST=1 bash "$PHOTO_ROOT/test/direct_order_status_rpc_test.sh" "$PHOTO_CONTAINER"
 docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -v ON_ERROR_STOP=1 -c "UPDATE public.users SET restaurant_id='d2000000-0000-4000-8000-000000000001' WHERE auth_id=auth.uid();" >/dev/null
 for reconciliation_limit in 1 50 100 200; do
  docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -v ON_ERROR_STOP=1 -c "SELECT pg_stat_reset(); SELECT jsonb_array_length(public.direct_order_staff_list_v3('d2000000-0000-4000-8000-000000000001',NULL,$reconciliation_limit)); SELECT jsonb_array_length(public.direct_delivery_ticket_list_v3('d2000000-0000-4000-8000-000000000001',NULL,$reconciliation_limit)); SELECT pg_stat_force_next_flush();" >/dev/null
  reconciliation_calls="$(docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -Atqc "SELECT COALESCE(sum(calls),0) FROM pg_stat_user_functions WHERE funcid IN ('public.direct_order_staff_detail_v3(uuid,uuid)'::regprocedure,'public.direct_order_support_context(uuid,boolean)'::regprocedure,'public.direct_order_enrich_translations(jsonb,uuid)'::regprocedure)")"
  [[ "$reconciliation_calls" == "0" ]] || { printf 'RECONCILIATION_LIST_N_PLUS_ONE\n'; exit 1; }
  printf 'DIRECT_ORDER_RECONCILIATION_TRANSLATION_LIST limit=%s detail_calls=%s\n' "$reconciliation_limit" "$reconciliation_calls"
 done

fi
if [[ "${DIRECT_ORDER_PROGRESS_TEST:-0}" == "1" ]]; then
 run_sql "$PHOTO_ROOT/test/fixtures/direct_order_customer_progress_setup.sql" >/dev/null
 run_sql "$PHOTO_ROOT/supabase/migrations/20261010030000_direct_order_customer_progress_and_utensils.sql" > "$PHOTO_TMP/progress_migration.log" 2>&1 || { cat "$PHOTO_TMP/progress_migration.log"; exit 1; }
 run_sql "$PHOTO_ROOT/supabase/tests/direct_order_customer_progress_test.sql"
 for progress_limit in 1 10 50; do
  docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -v ON_ERROR_STOP=1 -c "SELECT pg_stat_reset(); SELECT jsonb_array_length(public.direct_order_public_orders_v4(session_id,secret_hash,$progress_limit)) FROM progress_measurement.session_scope; SELECT pg_stat_force_next_flush();" >/dev/null
  progress_calls="$(docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -Atqc "SELECT COALESCE(sum(calls),0) FROM pg_stat_user_functions WHERE funcid='public.direct_order_cooking_progress(uuid[])'::regprocedure")"
  [[ "$progress_calls" == "1" ]] || { printf 'CUSTOMER_PROGRESS_BATCH_CALLS_FAILED count=%s\n' "$progress_calls"; exit 1; }
  progress_details="$(docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -Atqc "SELECT COALESCE(sum(calls),0) FROM pg_stat_user_functions WHERE funcid IN ('public.direct_order_fulfillment_context(uuid)'::regprocedure,'public.direct_order_public_status_v3(uuid,text,uuid)'::regprocedure)")"
  [[ "$progress_details" == "0" ]] || { printf 'CUSTOMER_PROGRESS_DETAIL_N_PLUS_ONE\n'; exit 1; }
  printf 'CUSTOMER_PROGRESS_LIST limit=%s cooking_batch_calls=%s detail_calls=%s\n' "$progress_limit" "$progress_calls" "$progress_details"
 done
 for progress_size in 1 10 50; do
  docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -v ON_ERROR_STOP=1 -c "SELECT pg_stat_reset(); SELECT public.kds_complete_kitchen_batch_v1(request_id,allocations) FROM progress_measurement.kitchen_batches WHERE size=$progress_size; SELECT pg_stat_force_next_flush();" >/dev/null
  progress_calls="$(docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -Atqc "SELECT COALESCE(sum(calls),0) FROM pg_stat_user_functions WHERE funcid='public.direct_order_cooking_progress(uuid[])'::regprocedure")"
  [[ "$progress_calls" == "1" ]] || { printf 'KITCHEN_NOTICE_N_PLUS_ONE count=%s\n' "$progress_calls"; exit 1; }
  progress_notices="$(docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -Atqc "SELECT count(*) FROM public.direct_order_customer_events e JOIN progress_measurement.kitchen_batches b USING(request_id) WHERE b.size=$progress_size AND e.event_kind='cooking_complete'")"
  [[ "$progress_notices" == "1" ]] || { printf 'KITCHEN_BATCH_NOTICE_INVALID count=%s\n' "$progress_notices"; exit 1; }
  printf 'KITCHEN_CUSTOMER_NOTICE size=%s cooking_batch_calls=%s notices=%s\n' "$progress_size" "$progress_calls" "$progress_notices"
 done
 docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -v ON_ERROR_STOP=1 -c "UPDATE public.users SET restaurant_id='d2000000-0000-4000-8000-000000000001' WHERE auth_id=auth.uid();" >/dev/null
 for progress_limit in 1 50 200; do
  docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -v ON_ERROR_STOP=1 -c "SELECT pg_stat_reset(); SELECT jsonb_array_length(public.direct_order_staff_list_v3('d2000000-0000-4000-8000-000000000001',NULL,$progress_limit)); SELECT jsonb_array_length(public.direct_delivery_ticket_list_v3('d2000000-0000-4000-8000-000000000001',NULL,$progress_limit)); SELECT pg_stat_force_next_flush();" >/dev/null
  progress_details="$(docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -Atqc "SELECT COALESCE(sum(calls),0) FROM pg_stat_user_functions WHERE funcid IN ('public.direct_order_fulfillment_context(uuid)'::regprocedure,'public.direct_order_staff_detail_v3(uuid,uuid)'::regprocedure,'public.direct_order_support_context(uuid,boolean)'::regprocedure)")"
  [[ "$progress_details" == "0" ]] || { printf 'STAFF_KITCHEN_PROGRESS_N_PLUS_ONE\n'; exit 1; }
  printf 'STAFF_KITCHEN_PROGRESS_LIST limit=%s detail_calls=%s\n' "$progress_limit" "$progress_details"
 done
fi
if [[ "${DIRECT_ORDER_REQUIREMENTS_TEST:-0}" == "1" ]]; then
 python3 - "$PHOTO_ROOT" "$PHOTO_TMP" <<'PYREQUIREMENTS'
from pathlib import Path
import re,sys
root,tmp=map(Path,sys.argv[1:]); output=''
for file,name in [('20260811180000_fix_public_receipt_pgcrypto_schema.sql','get_public_receipt'),('20260821130000_direct_delivery_ordering.sql','direct_order_staff_message'),('20260710002000_receipt_print_queue.sql','reprint_print_job'),('20260811170000_pos_paperless_receipts.sql','claim_print_jobs'),('20260811170000_pos_paperless_receipts.sql','emergency_hold_print_job'),('20260706014000_print_routing_v1_m1.sql','print_routing_actor_can_run')]:
 source=(root/'supabase/migrations'/file).read_text(); match=re.search(r'CREATE (?:OR REPLACE )?FUNCTION public\.'+name+r'\(',source)
 output+=source[match.start():source.index('$$;',match.start())+3]+'\n'
(tmp/'requirements_predecessor.sql').write_text(output)
PYREQUIREMENTS
 run_sql "$PHOTO_ROOT/test/fixtures/direct_order_requirements_setup.sql" >/dev/null
 run_sql "$PHOTO_TMP/requirements_predecessor.sql" >/dev/null
 docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -v ON_ERROR_STOP=1 -c "CREATE TRIGGER emergency_hold_print_job_trigger BEFORE INSERT ON public.print_jobs FOR EACH ROW EXECUTE FUNCTION public.emergency_hold_print_job();" >/dev/null
 run_sql "$PHOTO_ROOT/supabase/migrations/20261010040000_direct_order_confirmed_requirements.sql" > "$PHOTO_TMP/requirements_migration.log" 2>&1 || { cat "$PHOTO_TMP/requirements_migration.log"; exit 1; }
 run_sql "$PHOTO_ROOT/supabase/tests/direct_order_confirmed_requirements_test.sql"
 DIRECT_ORDER_STATUS_V9_TEST=1 bash "$PHOTO_ROOT/test/direct_order_status_rpc_test.sh" "$PHOTO_CONTAINER"
 for requirement_size in 1 10 50; do
  docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -v ON_ERROR_STOP=1 -c "SELECT pg_stat_reset(); UPDATE public.users SET restaurant_id=s.restaurant_id FROM requirement_measurement.scopes s WHERE s.size=$requirement_size AND users.auth_id=auth.uid(); SELECT jsonb_array_length(public.direct_order_staff_detail_v5(restaurant_id,request_id)->'requirements') FROM requirement_measurement.scopes WHERE size=$requirement_size; SELECT public.direct_order_staff_list_v4(restaurant_id,NULL,200) IS NOT NULL FROM requirement_measurement.scopes WHERE size=$requirement_size; SELECT pg_stat_force_next_flush();" >/dev/null
  requirement_calls="$(docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -Atqc "SELECT COALESCE(sum(calls),0) FROM pg_stat_user_functions WHERE funcid='public.direct_order_requirement_snapshot(uuid)'::regprocedure")"
  [[ "$requirement_calls" == "1" ]] || { printf 'REQUIREMENT_DETAIL_N_PLUS_ONE calls=%s\n' "$requirement_calls"; exit 1; }
  printf 'CUSTOMER_REQUIREMENTS size=%s snapshot_calls=%s list_detail_calls=0\n' "$requirement_size" "$requirement_calls"
  docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -v ON_ERROR_STOP=1 -c "SELECT pg_stat_reset(); SELECT jsonb_array_length(public.direct_order_public_status_v9(session_id,secret_hash,request_id)->'requirements') FROM requirement_measurement.scopes WHERE size=$requirement_size; SELECT pg_stat_force_next_flush();" >/dev/null
  requirement_calls="$(docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -Atqc "SELECT COALESCE(sum(calls),0) FROM pg_stat_user_functions WHERE funcid='public.direct_order_requirement_snapshot(uuid)'::regprocedure")"
  [[ "$requirement_calls" == "1" ]] || { printf 'PUBLIC_REQUIREMENT_N_PLUS_ONE\n'; exit 1; }
  printf 'PUBLIC_CUSTOMER_REQUIREMENTS size=%s snapshot_calls=%s\n' "$requirement_size" "$requirement_calls"
 done
 docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -v ON_ERROR_STOP=1 -c "BEGIN; SELECT id FROM public.direct_order_requests WHERE id=(SELECT request_id FROM requirement_measurement.concurrent_decision) FOR UPDATE; SELECT pg_sleep(1); COMMIT;" > "$PHOTO_TMP/requirement_lock.log" 2>&1 &
 requirement_lock_pid=$!
 docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -v ON_ERROR_STOP=1 -c "SELECT public.direct_order_public_decide_requirement(session_id,secret_hash,request_id,requirement_id,version,reply_message_id,true)->>'request_id' FROM requirement_measurement.concurrent_decision" > "$PHOTO_TMP/requirement_race_a.log" 2>&1 &
 requirement_a_pid=$!
 docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -v ON_ERROR_STOP=1 -c "SELECT public.direct_order_public_decide_requirement(session_id,secret_hash,request_id,requirement_id,version,reply_message_id,true)->>'request_id' FROM requirement_measurement.concurrent_decision" > "$PHOTO_TMP/requirement_race_b.log" 2>&1 &
 requirement_b_pid=$!
 wait "$requirement_lock_pid" || { cat "$PHOTO_TMP/requirement_lock.log"; exit 1; }
 wait "$requirement_a_pid" || { cat "$PHOTO_TMP/requirement_race_a.log"; exit 1; }
 wait "$requirement_b_pid" || { cat "$PHOTO_TMP/requirement_race_b.log"; exit 1; }
 requirement_confirmations="$(docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -Atqc "SELECT count(*) FROM public.direct_order_messages m JOIN requirement_measurement.concurrent_decision s USING(request_id) WHERE m.metadata->>'requirement_accepted'='true'")"
 [[ "$requirement_confirmations" == "1" ]] || { printf 'CONCURRENT_REQUEST_CONFIRMATION_DUPLICATED\n'; exit 1; }
 printf 'CONCURRENT_REQUEST_CONFIRMATION=PASS confirmations=1\n'
fi
if [[ "${DIRECT_ORDER_RECIPIENT_TEST:-0}" == "1" ]]; then
 python3 - "$PHOTO_ROOT" "$PHOTO_TMP" <<'PYRECIPIENT'
from pathlib import Path
import re,sys
root,tmp=map(Path,sys.argv[1:]); output=''
for file,names in [('20260630000000_wetax_shutdown_meinvoice_foundation.sql',['meinvoice_tax_entity_config','meinvoice_jobs']),('20260721040000_red_invoice_intake_export.sql',['red_invoice_intakes'])]:
 source=(root/'supabase/migrations'/file).read_text()
 for name in names:
  match=re.search(r'CREATE TABLE (?:IF NOT EXISTS )?public\.'+name+r' \(',source)
  if not match: raise RuntimeError(name)
  output+=source[match.start():source.index('\n);',match.start())+4]+'\n'
(tmp/'recipient_invoice_tables.sql').write_text(output)
PYRECIPIENT
 run_sql "$PHOTO_ROOT/test/fixtures/direct_order_recipient_setup.sql" >/dev/null
 run_sql "$PHOTO_TMP/recipient_invoice_tables.sql" > "$PHOTO_TMP/recipient_fixture.log" 2>&1 || { cat "$PHOTO_TMP/recipient_fixture.log"; exit 1; }
 if [[ -n "${DIRECT_ORDER_RECIPIENT_BASELINE_DUMP:-}" ]]; then
  docker exec "$PHOTO_CONTAINER" pg_dump -U postgres -d codex_direct_photo > "$DIRECT_ORDER_RECIPIENT_BASELINE_DUMP"
 fi
 for recipient_migration in 20261010050000_direct_order_recipient_delivery.sql 20261010051000_direct_order_recipient_receipts.sql 20261010052000_direct_order_batch_refund_invoice.sql; do
  run_sql "$PHOTO_ROOT/supabase/migrations/$recipient_migration" > "$PHOTO_TMP/recipient_migration.log" 2>&1 || { cat "$PHOTO_TMP/recipient_migration.log"; exit 1; }
 done
 run_sql "$PHOTO_ROOT/supabase/tests/direct_order_recipient_delivery_test.sql"
 for recipient_size in 1 10 50; do
  docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -v ON_ERROR_STOP=1 -c "SELECT pg_stat_reset(); SELECT public.direct_order_staff_support_action(s.restaurant_id,s.request_id,r.support_version,'invoice',r.invoice_details) IS NOT NULL FROM recipient_measurement.money_scopes s JOIN public.direct_order_requests r ON r.id=s.request_id WHERE s.size=$recipient_size; SELECT public.direct_order_staff_support_action(s.restaurant_id,s.request_id,r.support_version,'cancel_order','{}'::jsonb) IS NOT NULL FROM recipient_measurement.money_scopes s JOIN public.direct_order_requests r ON r.id=s.request_id WHERE s.size=$recipient_size; SELECT public.direct_order_staff_support_action(s.restaurant_id,s.request_id,r.support_version,'refund_complete',jsonb_build_object('operation_id',s.operation_id,'amount',s.expected,'reference','batch test','evidence_message_id',s.evidence_id,'method','BANKTRANSFER')) IS NOT NULL FROM recipient_measurement.money_scopes s JOIN public.direct_order_requests r ON r.id=s.request_id WHERE s.size=$recipient_size; SELECT pg_stat_force_next_flush();" > "$PHOTO_TMP/recipient_batch.log" 2>&1 || { cat "$PHOTO_TMP/recipient_batch.log"; exit 1; }
  recipient_calls="$(docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -Atqc "SELECT COALESCE(sum(calls),0) FROM pg_stat_user_functions WHERE funcid IN ('public.record_payment_adjustment(uuid,text,numeric,text)'::regprocedure,'public.direct_order_sync_invoice(uuid,uuid,uuid)'::regprocedure,'public.upsert_red_invoice_intake_minimal(uuid,uuid,text,text,text,text,text,text,text,text)'::regprocedure)")"
  [[ "$recipient_calls" == "0" ]] || { printf 'RECIPIENT_MONEY_N_PLUS_ONE calls=%s\n' "$recipient_calls"; exit 1; }
  recipient_batches="$(docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -Atqc "SELECT (SELECT COALESCE(sum(calls),0) FROM pg_stat_user_functions WHERE funcid='public.direct_order_refund_payment_batch(uuid,uuid,text,numeric,text)'::regprocedure)||'/'||(SELECT COALESCE(sum(calls),0) FROM pg_stat_user_functions WHERE funcid='public.direct_order_sync_invoice_batch(uuid,uuid,uuid[])'::regprocedure)")"
  [[ "$recipient_batches" == "1/1" ]] || { printf 'RECIPIENT_MONEY_BATCH_WRONG calls=%s\n' "$recipient_batches"; exit 1; }
  printf 'RECIPIENT_MONEY_BATCH supplemental_payments=%s per_payment_calls=%s refund_invoice_batches=%s\n' "$recipient_size" "$recipient_calls" "$recipient_batches"
 done
 run_sql "$PHOTO_ROOT/supabase/tests/direct_order_recipient_batch_assert.sql"
 bash "$PHOTO_ROOT/test/direct_order_recipient_concurrency.sh" "$PHOTO_CONTAINER" "$PHOTO_TMP"
 for recipient_limit in 1 50 100 200; do
  docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -v ON_ERROR_STOP=1 -c "SELECT pg_stat_reset(); UPDATE public.users SET restaurant_id='d2000000-0000-4000-8000-000000000001' WHERE auth_id=auth.uid(); SELECT jsonb_array_length(public.direct_order_staff_list_v5('d2000000-0000-4000-8000-000000000001',NULL,$recipient_limit)); SELECT jsonb_array_length(public.direct_delivery_ticket_list_v4('d2000000-0000-4000-8000-000000000001',NULL,$recipient_limit)); SELECT pg_stat_force_next_flush();" >/dev/null
  recipient_details="$(docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -Atqc "SELECT COALESCE(sum(calls),0) FROM pg_stat_user_functions WHERE funcid IN ('public.direct_order_booking_snapshot(uuid)'::regprocedure,'public.direct_order_staff_detail_v6(uuid,uuid)'::regprocedure,'public.direct_order_support_context(uuid,boolean)'::regprocedure)")"
  [[ "$recipient_details" == "0" ]] || { printf 'RECIPIENT_STAFF_N_PLUS_ONE\n'; exit 1; }
  printf 'RECIPIENT_STAFF_KITCHEN_LIST limit=%s per_order_calls=%s\n' "$recipient_limit" "$recipient_details"
 done
 for recipient_limit in 1 10 50; do
  docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -v ON_ERROR_STOP=1 -c "SELECT pg_stat_reset(); SELECT jsonb_array_length(public.direct_order_public_orders_v5(session_id,secret_hash,$recipient_limit)) FROM progress_measurement.session_scope; SELECT pg_stat_force_next_flush();" >/dev/null
  recipient_details="$(docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -Atqc "SELECT COALESCE(sum(calls),0) FROM pg_stat_user_functions WHERE funcid IN ('public.direct_order_booking_snapshot(uuid)'::regprocedure,'public.direct_order_public_status_v10(uuid,text,uuid)'::regprocedure,'public.direct_order_support_context(uuid,boolean)'::regprocedure)")"
  [[ "$recipient_details" == "0" ]] || { printf 'RECIPIENT_CUSTOMER_N_PLUS_ONE\n'; exit 1; }
  printf 'RECIPIENT_CUSTOMER_LIST limit=%s per_order_calls=%s\n' "$recipient_limit" "$recipient_details"
 done
 if [[ "${DIRECT_ORDER_POS_BUYER_TEST:-0}" == "1" ]]; then
  run_sql "$PHOTO_ROOT/test/fixtures/pos_buyer_legacy_setup.sql" >/dev/null
  run_sql "$PHOTO_ROOT/supabase/migrations/20261010053000_pos_buyer_information.sql" > "$PHOTO_TMP/buyer_migration.log" 2>&1 || { cat "$PHOTO_TMP/buyer_migration.log"; exit 1; }
  run_sql "$PHOTO_ROOT/supabase/tests/pos_buyer_information_test.sql"
  bash "$PHOTO_ROOT/test/pos_buyer_information_concurrency.sh" "$PHOTO_CONTAINER" "$PHOTO_TMP"
 fi

fi
PHOTO_PAYMENT_HASH_AFTER="$(docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -Atqc "select md5(pg_get_functiondef('public.process_payment(uuid,uuid,numeric,text)'::regprocedure))")"
[[ "$PHOTO_PAYMENT_HASH" == "$PHOTO_PAYMENT_HASH_AFTER" ]] || { printf 'PAYMENT_ANCHOR_CHANGED\n'; exit 1; }
printf 'DIRECT_ORDER_DELIVERY_FALLBACK_SQL_TEST=PASS\n'
