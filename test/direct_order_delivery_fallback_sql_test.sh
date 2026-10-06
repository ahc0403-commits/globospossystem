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
out+="ALTER TABLE direct_order_requests ADD COLUMN fulfillment_type text NOT NULL DEFAULT 'delivery';\n"
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
run_sql "$PHOTO_ROOT/supabase/migrations/20261006010000_direct_order_receipt_packing_context.sql" >/dev/null
run_sql "$PHOTO_ROOT/supabase/tests/direct_order_receipt_packing_contract_test.sql"
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
PHOTO_PAYMENT_HASH_AFTER="$(docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -Atqc "select md5(pg_get_functiondef('public.process_payment(uuid,uuid,numeric,text)'::regprocedure))")"
[[ "$PHOTO_PAYMENT_HASH" == "$PHOTO_PAYMENT_HASH_AFTER" ]] || { printf 'PAYMENT_ANCHOR_CHANGED\n'; exit 1; }
printf 'DIRECT_ORDER_DELIVERY_FALLBACK_SQL_TEST=PASS\n'
