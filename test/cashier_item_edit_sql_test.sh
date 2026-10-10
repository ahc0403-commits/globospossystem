#!/usr/bin/env bash
set -euo pipefail
EDIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EDIT_TMP="$(mktemp -d)"
EDIT_CONTAINER="globos-cashier-items-test-$$"
cleanup() { docker rm -f "$EDIT_CONTAINER" >/dev/null 2>&1 || true; rm -rf "$EDIT_TMP"; }
trap cleanup EXIT
python3 - "$EDIT_ROOT" "$EDIT_TMP" <<'PY'
from pathlib import Path
import sys,re
root,tmp=map(Path,sys.argv[1:]);mdir=root/'supabase/migrations'
def text(name): return (mdir/name).read_text()
def function(name,fn):
 s=text(name);m=re.search(r'CREATE (?:OR REPLACE )?FUNCTION public\.'+fn+r'\(',s);return s[m.start():s.index('$$;',m.start())+3]+'\n'
def table(name,t):
 s=text(name);m=re.search(r'CREATE TABLE (?:IF NOT EXISTS )?public\.'+t+r' \(',s);return s[m.start():s.index('\n);',m.start())+4]+'\n'
s='''
ALTER TABLE users ADD COLUMN restaurant_id uuid;
ALTER TABLE tables ADD COLUMN restaurant_id uuid,ADD COLUMN table_number text,ADD COLUMN floor_label text,ADD COLUMN updated_at timestamptz DEFAULT now();
ALTER TABLE orders ADD COLUMN sales_channel text DEFAULT 'dine_in',ADD COLUMN guest_count integer,ADD COLUMN created_by uuid,ADD COLUMN notes text,ADD COLUMN order_source text DEFAULT 'staff',ADD COLUMN fulfillment_mode_snapshot text DEFAULT 'pos_print';
ALTER TABLE order_items ADD COLUMN notes text,ADD COLUMN combo_components jsonb DEFAULT '[]',ADD COLUMN fulfillment_route_snapshot text DEFAULT 'kitchen_tray_floor',ADD COLUMN fulfillment_mode_snapshot text DEFAULT 'pos_print';
ALTER TABLE menu_items ADD COLUMN restaurant_id uuid,ADD COLUMN name text,ADD COLUMN name_ko text,ADD COLUMN name_vi text,ADD COLUMN name_en text,ADD COLUMN is_combo boolean DEFAULT false;
ALTER TABLE order_discounts ADD COLUMN void_reason text;
CREATE TABLE direct_order_financials(order_id uuid);
'''
base='20260810170000_emergency_digital_fulfillment.sql'
for t in ['emergency_fulfillment_sessions','emergency_order_queue','emergency_fulfillment_items','emergency_fulfillment_events']: s+=table(base,t)
s+=table('20260816190000_kds_combo_component_progress.sql','emergency_combo_component_items')
s+=table('20260812150000_floor_direct_beverage_fulfillment.sql','emergency_floor_direct_items')
s+=table('20260916190000_kds_start_ready_serve_workflow.sql','emergency_floor_ready_lots')
s+=table('20260917150000_kds_kitchen_complete_tray_handoff_batch.sql','emergency_tray_ready_lots')
s+=table('20260807170000_cashier_cancellation_immutable_ledger.sql','order_cancellation_ledger')
s+='ALTER TABLE order_cancellation_ledger ADD COLUMN order_status_snapshot text;\n'
s+=table('20260807200000_cancellation_restore_and_live_sales.sql','order_cancellation_reversals')
s+='ALTER TABLE emergency_order_queue ADD COLUMN workflow_version smallint DEFAULT 2;\n'
for t in ['emergency_fulfillment_items','emergency_combo_component_items']: s+='ALTER TABLE '+t+' ADD COLUMN kitchen_started_quantity integer DEFAULT 0,ADD COLUMN excused_quantity integer DEFAULT 0;\n'
s+='ALTER TABLE emergency_floor_direct_items ADD COLUMN excused_quantity integer DEFAULT 0;\n'
s+=function(base,'emergency_floor_label')
s+='CREATE FUNCTION emergency_enqueue_push(uuid,uuid,uuid,text,text,text) RETURNS void LANGUAGE sql AS $$ SELECT NULL::void $$;\n'
s+=function('20260812151000_floor_direct_beverage_runtime.sql','emergency_upsert_floor_direct_line')
s+=function('20260812151000_floor_direct_beverage_runtime.sql','emergency_sync_order_item')
s+=function('20260816190000_kds_combo_component_progress.sql','emergency_sync_combo_component_items')
s+='CREATE TRIGGER emergency_sync_order_item_trigger AFTER INSERT OR UPDATE ON order_items FOR EACH ROW EXECUTE FUNCTION emergency_sync_order_item();\nCREATE TRIGGER zz_emergency_sync_combo_component_items_trigger AFTER INSERT OR UPDATE ON order_items FOR EACH ROW EXECUTE FUNCTION emergency_sync_combo_component_items();\n'
# Use production progress constraints and preserve-started trigger, not permissive fixture counters.
workflow=text('20260916190000_kds_start_ready_serve_workflow.sql');start=workflow.index('ALTER TABLE public.emergency_fulfillment_items\n  DROP CONSTRAINT');end=workflow.index('ALTER TABLE public.emergency_fulfillment_events',start);s+=workflow[start:end]
s+=function('20260810120000_immediate_kitchen_tray_copy.sql','recalc_order_status')
s+=function('20260706010000_discount_staff_meal_v1_schema.sql','void_active_order_discount_for_item_change')
s+=function('20260917100000_kds_menu_cancellation.sql','cancel_order_item')
s+=function('20260917100000_kds_menu_cancellation.sql','restore_cancelled_order_item')
s+=function('20260707010000_service_item_exclusion_v1.sql','process_payment')
s+='ALTER FUNCTION process_payment(uuid,uuid,numeric,text) RENAME TO process_payment_without_scoped_promotions;\nCREATE FUNCTION process_payment(uuid,uuid,numeric,text) RETURNS payments LANGUAGE sql AS $$ SELECT public.process_payment_without_scoped_promotions($1,$2,$3,$4); $$;\n'
# Same quantity/VAT setter invoked by normal orders.
s+=function('20260428000002_vat_pricing_mode.sql','compute_order_item_tax_amounts') if 'CREATE OR REPLACE FUNCTION public.compute_order_item_tax_amounts(' in text('20260428000002_vat_pricing_mode.sql') else ''
(tmp/'setup.sql').write_text(s)
PY
docker run --detach --rm --name "$EDIT_CONTAINER" --env POSTGRES_HOST_AUTH_METHOD=trust postgres:15 >/dev/null
for ((attempt=0;attempt<60;attempt++)); do
 if docker exec "$EDIT_CONTAINER" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1; then break; fi
 sleep 1
done
run_sql() { docker exec -i "$EDIT_CONTAINER" psql -X -U postgres -v ON_ERROR_STOP=1 < "$1"; }
run_sql "$EDIT_ROOT/test/fixtures/restaurant_vat_integrity_setup.sql" >/dev/null
run_sql "$EDIT_TMP/setup.sql" > "$EDIT_TMP/setup.log" 2>&1 || { cat "$EDIT_TMP/setup.log"; exit 1; }
run_sql "$EDIT_ROOT/supabase/migrations/20261009152000_cashier_item_move_and_partial_cancel.sql" > "$EDIT_TMP/migration.log" 2>&1 || { cat "$EDIT_TMP/migration.log"; exit 1; }
run_sql "$EDIT_ROOT/supabase/tests/cashier_item_move_and_partial_cancel_test.sql"
# Run two real transactions: payment owns the order while movement owns the
# table. Movement must fail promptly without deadlocking or rewriting payment.
docker exec -i "$EDIT_CONTAINER" psql -X -U postgres -v ON_ERROR_STOP=1 > "$EDIT_TMP/race-fixture.log" <<'SQL'
CREATE TABLE cashier_race_fixture(store_id uuid,order_id uuid,item_id uuid,target_table_id uuid);
DO $$ DECLARE store uuid; menu uuid; source_table uuid:=gen_random_uuid(); target uuid:=gen_random_uuid(); o uuid; i uuid; BEGIN
 SELECT restaurant_id,menu_item_id INTO store,menu FROM order_items LIMIT 1;
 INSERT INTO tables(id,restaurant_id,table_number,status) VALUES(source_table,store,'race-source','occupied'),(target,store,'race-destination','available');
 INSERT INTO orders(restaurant_id,table_id,status) VALUES(store,source_table,'serving') RETURNING id INTO o;
 INSERT INTO order_items(restaurant_id,order_id,menu_item_id,label,unit_price,quantity,status,vat_rate,paying_amount_inc_tax,vat_amount,total_amount_ex_tax) VALUES(store,o,menu,'Race drink',10000,1,'ready',8,10800,800,10000) RETURNING id INTO i;
 INSERT INTO cashier_race_fixture VALUES(store,o,i,target);
END $$;
SQL
docker exec -i --env PGAPPNAME=cashier_payment_race "$EDIT_CONTAINER" psql -X -U postgres -v ON_ERROR_STOP=1 > "$EDIT_TMP/payment-race.log" 2>&1 <<'SQL' &
BEGIN;
SELECT 1 FROM orders WHERE id=(SELECT order_id FROM cashier_race_fixture) FOR UPDATE;
SELECT pg_sleep(2);
SELECT public.process_payment(order_id,store_id,10800,'CASH') FROM cashier_race_fixture;
COMMIT;
SQL
PAYMENT_RACE_PID=$!
RACE_LOCK_READY=0
for ((attempt=0;attempt<100;attempt++)); do
 if [[ "$(docker exec "$EDIT_CONTAINER" psql -X -U postgres -Atc "SELECT count(*) FROM pg_stat_activity WHERE application_name='cashier_payment_race' AND query='SELECT pg_sleep(2);'")" == 1 ]]; then RACE_LOCK_READY=1;break;fi
 sleep 0.02
done
[[ "$RACE_LOCK_READY" == 1 ]] || { cat "$EDIT_TMP/payment-race.log";exit 1; }
docker exec -i "$EDIT_CONTAINER" psql -X -U postgres -v ON_ERROR_STOP=1 <<'SQL'
DO $$ DECLARE f cashier_race_fixture%ROWTYPE;BEGIN
 SELECT * INTO f FROM cashier_race_fixture;
 BEGIN
  PERFORM public.cashier_move_order_items(f.store_id,f.order_id,f.target_table_id,jsonb_build_array(jsonb_build_object('item_id',f.item_id,'quantity',1,'expected_quantity',1)),gen_random_uuid());
  RAISE EXCEPTION 'MOVEMENT_OVERWROTE_CONCURRENT_PAYMENT';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'CASHIER_ITEM_CHANGED' THEN RAISE;END IF;END;
END $$;
SQL
wait "$PAYMENT_RACE_PID" || { cat "$EDIT_TMP/payment-race.log";exit 1; }
docker exec -i "$EDIT_CONTAINER" psql -X -U postgres -v ON_ERROR_STOP=1 <<'SQL'
DO $$ DECLARE f cashier_race_fixture%ROWTYPE;BEGIN
 SELECT * INTO f FROM cashier_race_fixture;
 IF NOT EXISTS(SELECT 1 FROM payments WHERE order_id=f.order_id AND amount=10800) OR (SELECT order_id FROM order_items WHERE id=f.item_id)<>f.order_id OR (SELECT status FROM tables WHERE id=f.target_table_id)<>'available' THEN RAISE EXCEPTION 'PAYMENT_MOVE_RACE_CORRUPTED'; END IF;
END $$;
SELECT 'CASHIER_CONCURRENT_PAYMENT_MOVE=PASS';
SQL

printf 'CASHIER_ITEM_EDIT_SQL_TEST=PASS\n'
