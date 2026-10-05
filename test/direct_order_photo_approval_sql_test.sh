#!/usr/bin/env bash
set -euo pipefail
PHOTO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PHOTO_TMP="$(mktemp -d)"
PHOTO_CONTAINER="globos-direct-photo-test-$$"
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
out+=function(base,'direct_delivery_ticket_list')
out+='REVOKE ALL ON FUNCTION public.direct_delivery_ticket_list(uuid,text[],timestamptz,uuid,integer) FROM PUBLIC,anon;\n'
out+='GRANT EXECUTE ON FUNCTION public.direct_delivery_ticket_list(uuid,text[],timestamptz,uuid,integer) TO authenticated;\n'
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
# Apply the exact current-main edits to the approval anchor, including pickup
# order provenance and delivery-mode snapshots, without unrelated dependencies.
pickup=source('20261002030000_direct_order_delivery_pickup.sql')
latest=''
for match in re.finditer(r'ALTER TABLE public\.direct_order_(?:requests|quotes|financials)\b[\s\S]*?;',pickup):
 latest+=match.group()+'\n'
start=pickup.index('CREATE FUNCTION pg_temp.direct_pickup_patch(')
latest+=pickup[start:pickup.index('$$;',start)+3]+'\n'
for match in re.finditer(r"SELECT pg_temp\.direct_pickup_patch\('public\.direct_order_approve_payment\([\s\S]*?\$new\$\);",pickup):
 latest+=match.group()+'\n'
if latest.count('SELECT pg_temp.direct_pickup_patch(')!=7:
 raise RuntimeError('Current-main pickup approval anchors changed')
(tmp/'current-main-approval.sql').write_text(latest)
# The operating-hours regression reuses this disposable real-payment database.
hours=''
for file,name in [
 (base,'direct_order_validate_session'),
 (base,'direct_order_public_storefront'),
 (base,'direct_order_admin_upsert_storefront'),
 ('20260907130000_direct_delivery_manual_addresses.sql','direct_order_public_submit'),
 ('20260907150000_cashier_direct_delivery_availability.sql','direct_order_staff_get_availability'),
 ('20260907150000_cashier_direct_delivery_availability.sql','direct_order_staff_set_paused'),
 ('20260811170000_pos_paperless_receipts.sql','get_store_fulfillment_mode'),
 ('20260824060000_direct_delivery_kds_routing.sql','capture_order_item_fulfillment_mode'),
 ('20260812151000_floor_direct_beverage_runtime.sql','emergency_sync_order_item'),
 ('20260810170000_emergency_digital_fulfillment.sql','emergency_floor_label'),
 ('20260815170000_kds_card_menu_sync.sql','get_emergency_station_snapshot'),
 ('20260810170000_emergency_digital_fulfillment.sql','emergency_record_progress'),
]: hours+=function(file,name)
(tmp/'hours-functions.sql').write_text(hours)
(tmp/'delivery-progress-function.sql').write_text(function(
 '20260917150000_kds_kitchen_complete_tray_handoff_batch.sql',
 'emergency_preserve_started_quantity'))
# Real KDS routing, revision fanout and ticket reads for approved pickup.
start=pickup.index('CREATE FUNCTION pg_temp.direct_pickup_patch(')
pickup_functions=pickup[start:pickup.index('$$;',start)+3]+'\n'
for file,name in [
 ('20261002030000_direct_order_delivery_pickup.sql','direct_order_is_pickup_pos_order'),
 (base,'direct_delivery_ticket_transition'),
 ('20260811140000_emergency_kds_order_actions.sql','emergency_complete_order_stage'),
 ('20260811140000_emergency_kds_order_actions.sql','emergency_revert_order_action'),
 ('20261002030000_direct_order_delivery_pickup.sql','direct_order_cashier_complete_pickup'),
 ('20260824060000_direct_delivery_kds_routing.sql','emergency_add_order_sales_channels'),
 ('20260824060000_direct_delivery_kds_routing.sql','emergency_enqueue_push'),
 ('20260824060000_direct_delivery_kds_routing.sql','sync_direct_delivery_ticket_from_kds'),
 ('20260831010000_kds_realtime_v2.sql','kds_change_envelope'),
 ('20260831010000_kds_realtime_v2.sql','kds_append_change'),
 ('20260831010000_kds_realtime_v2.sql','kds_capture_fulfillment_event'),
 ('20260831010000_kds_realtime_v2.sql','get_kds_ticket_v2'),
 ('20260917150000_kds_kitchen_complete_tray_handoff_batch.sql','kds_set_workflow_event_targets'),
]: pickup_functions+=function(file,name)
pickup_functions+='REVOKE ALL ON FUNCTION public.direct_order_is_pickup_pos_order(uuid,uuid) FROM PUBLIC,anon,authenticated;\n'
# Reuse the exact current-main mode-gate edit (the older payment fixture
# intentionally started in print mode until the KDS regressions were loaded).
mode_source=source('20260824013000_direct_delivery_pilot_open_hours.sql')
old_mode=re.search(r'v_old_mode_gate constant text := \$old\$([\s\S]*?)\$old\$;',mode_source).group(1)
new_mode=re.search(r'v_new_mode_gate constant text := \$new\$([\s\S]*?)\$new\$;',mode_source).group(1)
pickup_functions+="SELECT pg_temp.direct_pickup_patch('public.direct_order_approve_payment(uuid,uuid,numeric,text)', $old$"+old_mode+"$old$, $new$"+new_mode+"$new$);\n"

# Apply the exact pickup lifecycle edits, including its legacy KDS exclusion.
for signature in ['public.direct_delivery_ticket_transition(', 'public.sync_direct_delivery_ticket_from_kds(', 'public.emergency_sync_order_item(']:
 for match in re.finditer(r"SELECT pg_temp\.direct_pickup_patch\('"+re.escape(signature)+r"[\s\S]*?\$new\$\);",pickup):
  pickup_functions+=match.group()+'\n'
pickup_functions+='CREATE TRIGGER sync_direct_delivery_ticket_from_kds_trigger AFTER INSERT ON public.emergency_fulfillment_events FOR EACH ROW EXECUTE FUNCTION public.sync_direct_delivery_ticket_from_kds();\n'
pickup_functions+='CREATE TRIGGER kds_capture_fulfillment_event_trigger AFTER INSERT ON public.emergency_fulfillment_events FOR EACH ROW EXECUTE FUNCTION public.kds_capture_fulfillment_event();\n'
pickup_functions+='CREATE TRIGGER zzz_kds_set_workflow_event_targets_trigger AFTER INSERT ON public.emergency_fulfillment_events FOR EACH ROW EXECUTE FUNCTION public.kds_set_workflow_event_targets();\n'
(tmp/'pickup-functions.sql').write_text(pickup_functions)
realtime=source('20260831010000_kds_realtime_v2.sql')
pickup_tables=''
for name in ['kds_realtime_rollouts','kds_store_revisions','kds_change_log']:
 start=realtime.index('CREATE TABLE IF NOT EXISTS public.'+name+' (')
 pickup_tables+=realtime[start:realtime.index('\n);',start)+4]+'\n'
(tmp/'pickup-realtime-tables.sql').write_text(pickup_tables)
PY
docker run --detach --rm --name "$PHOTO_CONTAINER" \
 --env POSTGRES_HOST_AUTH_METHOD=trust --env POSTGRES_DB=codex_direct_photo postgres:15 >/dev/null
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
run_sql "$PHOTO_TMP/current-main-approval.sql" >/dev/null
run_sql "$PHOTO_ROOT/test/fixtures/direct_order_photo_approval_requests.sql" >/dev/null
# The original failure is reproduced before applying the fix.
run_sql "$PHOTO_ROOT/test/sql/direct_order_photo_approval_before.sql"
PHOTO_PAYMENT_HASH="$(docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -Atqc \
 "select md5(pg_get_functiondef('public.process_payment(uuid,uuid,numeric,text)'::regprocedure))")"
PHOTO_APPROVAL_HASH="$(docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -Atqc \
 "select md5(pg_get_functiondef('public.direct_order_approve_payment(uuid,uuid,numeric,text)'::regprocedure))")"
run_sql "$PHOTO_ROOT/supabase/migrations/20261003060838_direct_order_customer_photo_approval.sql" >/dev/null
PHOTO_PAYMENT_HASH_AFTER="$(docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -Atqc \
 "select md5(pg_get_functiondef('public.process_payment(uuid,uuid,numeric,text)'::regprocedure))")"
[[ "$PHOTO_PAYMENT_HASH" == "$PHOTO_PAYMENT_HASH_AFTER" ]] || { printf 'PAYMENT_ANCHOR_CHANGED\n'; exit 1; }
run_sql "$PHOTO_ROOT/supabase/tests/direct_order_photo_approval_contract_test.sql"
# Two independent database sessions approve the same reviewed photo.
PHOTO_ARGS="$(docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -Atqc \
 "select concat_ws(',',f->>'store_id',f->>'request_id',f->>'quote_id',f->>'proof_id') from (select photo_test.create_request() f) x")"
IFS=',' read -r PHOTO_STORE PHOTO_REQUEST PHOTO_QUOTE PHOTO_PROOF <<< "$PHOTO_ARGS"
PHOTO_CALL="select set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000001',false); select public.direct_order_approve_photo_payment('$PHOTO_STORE','$PHOTO_REQUEST',108000,'$PHOTO_QUOTE','$PHOTO_PROOF');"
docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -v ON_ERROR_STOP=1 -c "$PHOTO_CALL" > "$PHOTO_TMP/a.log" 2>&1 &
PHOTO_PID_A=$!
docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -v ON_ERROR_STOP=1 -c "$PHOTO_CALL" > "$PHOTO_TMP/b.log" 2>&1 &
PHOTO_PID_B=$!
wait "$PHOTO_PID_A" || { cat "$PHOTO_TMP/a.log"; exit 1; }
wait "$PHOTO_PID_B" || { cat "$PHOTO_TMP/b.log"; exit 1; }
docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -v ON_ERROR_STOP=1 -c \
 "select photo_test.assert_single_graph('$PHOTO_REQUEST'); DO \$\$ BEGIN IF (SELECT current_stock FROM public.inventory_items LIMIT 1)<>9990 THEN RAISE EXCEPTION 'CONCURRENT_APPROVAL_DUPLICATED_STOCK_DEDUCTION'; END IF; END \$\$;" >/dev/null
# The identical production smoke runs with real cashier/kitchen role boundaries,
# then proves its synthetic financial and inventory writes were rolled back.
PHOTO_SMOKE_REQUEST="$(docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -Atqc \
 "select photo_test.create_request()->>'request_id'")"
docker exec -i "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -v ON_ERROR_STOP=1 -v "photo_smoke_request_id=$PHOTO_SMOKE_REQUEST" < "$PHOTO_ROOT/scripts/smoke_direct_order_customer_photo_approval.sql"
docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -v ON_ERROR_STOP=1 -c \
 "select photo_test.assert_empty_graph('$PHOTO_SMOKE_REQUEST'); DO \$\$ BEGIN IF (SELECT current_stock FROM public.inventory_items LIMIT 1)<>9990 THEN RAISE EXCEPTION 'PRODUCTION_SMOKE_DID_NOT_ROLL_BACK_STOCK'; END IF; END \$\$;" >/dev/null
run_sql "$PHOTO_ROOT/scripts/rollback_direct_order_customer_photo_approval.sql" >/dev/null
PHOTO_ROLLBACK_HASH="$(docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -Atqc \
 "select md5(pg_get_functiondef('public.direct_order_approve_payment(uuid,uuid,numeric,text)'::regprocedure))")"
[[ "$PHOTO_APPROVAL_HASH" == "$PHOTO_ROLLBACK_HASH" ]] || { printf 'ROLLBACK_CHANGED_UNRELATED_APPROVAL_LOGIC\n'; exit 1; }
run_sql "$PHOTO_ROOT/supabase/migrations/20261003060838_direct_order_customer_photo_approval.sql" >/dev/null
printf 'DIRECT_ORDER_PHOTO_APPROVAL_SQL_TEST=PASS\n'
printf 'DIRECT_ORDER_PHOTO_APPROVAL_CONCURRENCY=PASS\n'
printf 'DIRECT_ORDER_PHOTO_APPROVAL_ROLLBACK=PASS\n'
printf 'DIRECT_ORDER_PHOTO_APPROVAL_OPERATIONAL_SMOKE=PASS\n'
if [[ "${DELIVERY_HOURS_TEST:-0}" == 1 ]]; then
  run_sql "$PHOTO_ROOT/test/fixtures/delivery_hours_and_kds_fee_setup.sql" >/dev/null
  run_sql "$PHOTO_TMP/hours-functions.sql" >/dev/null
  run_sql "$PHOTO_ROOT/supabase/tests/fixtures/direct_delivery_test_clock.sql" >/dev/null
  run_sql "$PHOTO_ROOT/test/sql/delivery_hours_and_kds_fee_before.sql"
  run_sql "$PHOTO_ROOT/supabase/migrations/20261003093000_delivery_hours_and_kds_fee_exclusion.sql" >/dev/null
  run_sql "$PHOTO_ROOT/supabase/tests/delivery_hours_and_kds_fee_exclusion_test.sql"
  printf 'DELIVERY_HOURS_AND_KDS_FEE_SQL_TEST=PASS\n'
  run_sql "$PHOTO_ROOT/test/fixtures/delivery_individual_progress_setup.sql" >/dev/null
  run_sql "$PHOTO_TMP/delivery-progress-function.sql" >/dev/null
  run_sql "$PHOTO_ROOT/test/sql/delivery_individual_progress_before.sql"
  run_sql "$PHOTO_ROOT/supabase/migrations/20261003100000_delivery_individual_kitchen_progress.sql" >/dev/null
  run_sql "$PHOTO_ROOT/supabase/tests/delivery_individual_kitchen_progress_test.sql"
  run_sql "$PHOTO_ROOT/test/fixtures/direct_pickup_kds_setup.sql" >/dev/null
  run_sql "$PHOTO_TMP/pickup-realtime-tables.sql" >/dev/null
  run_sql "$PHOTO_TMP/pickup-functions.sql" >/dev/null
  run_sql "$PHOTO_ROOT/test/sql/direct_pickup_kds_before.sql"
  run_sql "$PHOTO_ROOT/supabase/migrations/20261005010000_direct_pickup_kds_handoff.sql" >/dev/null
  run_sql "$PHOTO_ROOT/supabase/tests/direct_pickup_kds_handoff_test.sql"
  # Two recovery sessions execute the exact operational script concurrently.
  PICKUP_RECOVERY_ARGS="$(docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -Atqc \
    "select concat_ws(',',request->>'store_id',request->>'request_id') from pickup_kds_test.stranded")"
  IFS=',' read -r PICKUP_RECOVERY_STORE PICKUP_RECOVERY_REQUEST <<< "$PICKUP_RECOVERY_ARGS"
  for worker in a b; do
    docker exec -i "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -v ON_ERROR_STOP=1 \
      -v "pickup_store_id=$PICKUP_RECOVERY_STORE" -v "pickup_request_id=$PICKUP_RECOVERY_REQUEST" \
      < "$PHOTO_ROOT/scripts/recover_direct_pickup_kds_order.sql" > "$PHOTO_TMP/recovery-$worker.log" 2>&1 &
    if [[ "$worker" == a ]]; then PICKUP_RECOVERY_PID_A=$!; else PICKUP_RECOVERY_PID_B=$!; fi
  done
  wait "$PICKUP_RECOVERY_PID_A" || { cat "$PHOTO_TMP/recovery-a.log"; exit 1; }
  wait "$PICKUP_RECOVERY_PID_B" || { cat "$PHOTO_TMP/recovery-b.log"; exit 1; }
  docker exec "$PHOTO_CONTAINER" psql -X -U postgres -d codex_direct_photo -v ON_ERROR_STOP=1 -c \
    "DO \$\$ DECLARE o uuid; h text; BEGIN SELECT (approval->>'order_id')::uuid,financial_hash INTO o,h FROM pickup_kds_test.stranded; ASSERT (SELECT count(*)=1 FROM public.emergency_order_queue WHERE order_id=o); ASSERT (SELECT count(*)=1 FROM public.emergency_fulfillment_items WHERE order_id=o); ASSERT h=pickup_kds_test.financial_hash(o); END \$\$;" >/dev/null
  printf 'DIRECT_PICKUP_OPERATIONAL_RECOVERY_CONCURRENCY=PASS\n'
fi
