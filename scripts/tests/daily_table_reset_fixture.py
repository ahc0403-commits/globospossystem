"""Load real legacy order/QR/cancellation bodies into a small isolated schema.

Printing/promotion enrichment are fixture boundaries; the order selection,
idempotency, actor checks, parent derivation and cancellation bodies are source.
"""
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
output = pathlib.Path(sys.argv[2])


def function(file, name, rename=None):
    source = (root / "supabase/migrations" / file).read_text()
    pattern = rf"CREATE OR REPLACE FUNCTION public\.{name}\([\s\S]*?\n\$\$[\s\S]*?;"
    match = re.search(pattern, source)
    if not match:
        raise RuntimeError(f"Missing source function {file}:{name}")
    body = match.group()
    if rename:
        body = body.replace(f"FUNCTION public.{name}(", f"FUNCTION public.{rename}(", 1)
    return body


parts = [(root / "test/fixtures/daily_table_operational_reset_setup.sql").read_text()]
parts.append(function("20260810120000_immediate_kitchen_tray_copy.sql", "recalc_order_status"))
parts.append(function("20260706014000_print_routing_v1_m1.sql", "create_order", "create_order_pre_takeout_core"))
parts.append(function("20260823010000_takeout_leftover_packaging.sql", "create_order"))
parts.append(function("20260513020000_operational_stability_closure.sql", "create_order_with_client_mutation_id"))
parts.append(function("20260917120000_cashier_order_cancellation.sql", "cancel_order"))
parts.append(function("20260917120000_cashier_order_cancellation.sql", "restore_cancelled_order"))
parts.append(function("20260901130000_operational_order_business_day_scope.sql", "search_active_order_for_cashier"))
core = function("20260808140000_qr_additional_order_print_delta.sql", "qr_place_order", "qr_place_order_pre_takeout_core")
# The production display-reset migration removed the partial-payment ban.
core = re.sub(r"    IF EXISTS \(\n      SELECT 1\n      FROM public.payments p[\s\S]*?    END IF;", "    NULL;", core, count=1)
parts.append(core)
parts.append("""
CREATE FUNCTION qr_place_order(p_token text,p_items jsonb,p_client_order_id uuid,p_validate_combo_choices boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth AS $$
BEGIN RETURN qr_place_order_pre_takeout_core(p_token,p_items,p_client_order_id); END $$;
CREATE FUNCTION create_buffet_order(p_store_id uuid,p_table_id uuid,p_guest_count integer,p_extra_items jsonb DEFAULT '[]')
RETURNS orders LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,auth AS $$
BEGIN RETURN create_order(p_store_id,p_table_id,p_extra_items); END $$;
""")
parts.append(function("20260909160000_qr_order_display_reset.sql", "qr_place_order", "qr_place_order_before_non_revenue_guard"))
parts.append(function("20260923010000_non_revenue_checkout_concurrency.sql", "qr_place_order"))
parts.append(function("20260812154000_qr_floor_direct_delivery_progress.sql", "qr_get_active_order", "qr_get_active_order_pre_takeout"))
parts.append(function("20260823010000_takeout_leftover_packaging.sql", "qr_get_active_order", "qr_get_active_order_pre_display_reset"))
parts.append(function("20260909160000_qr_order_display_reset.sql", "qr_get_active_order", "qr_get_active_order_pre_start_ready"))
parts.append(function("20260916190000_kds_start_ready_serve_workflow.sql", "qr_get_active_order"))
parts.append("""
GRANT SELECT ON users,restaurants,tables,orders,order_items,payments TO authenticated;
SET request.jwt.claim.sub='91000000-0000-4000-8000-000000000003';
SET request.jwt.claim.role='authenticated';
INSERT INTO table_qr_tokens(restaurant_id,table_id,token) VALUES(test_uuid(1),test_uuid(101),'incident-qr');
INSERT INTO orders(id,restaurant_id,table_id,status,created_at)
VALUES(test_uuid(1001),test_uuid(1),test_uuid(101),'serving',
 ((now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh')-interval '2 hours');
INSERT INTO order_items(order_id,restaurant_id,menu_item_id,status,created_at)
SELECT id,restaurant_id,test_uuid(10),'ready',created_at FROM orders WHERE id=test_uuid(1001);
UPDATE tables SET status='occupied' WHERE id=test_uuid(101);
SELECT test_assert(search_active_order_for_cashier(test_uuid(1),'1') IS NULL,'reproduce: cashier cannot find previous-day order');
SELECT test_assert((qr_get_active_order('incident-qr')->>'active')::boolean,'reproduce: QR shows previous-day order');
SELECT test_assert(qr_place_order('incident-qr','[{"menu_item_id":"91000000-0000-4000-8000-000000000011","quantity":1}]',
 test_uuid(1500),true,test_uuid(1001))->>'order_id'=test_uuid(1001)::text,'reproduce: new QR items attach to old order');
UPDATE order_items SET status='ready' WHERE order_id=test_uuid(1001);
SELECT recalc_order_status(test_uuid(1001));
""")
output.write_text("\n".join(parts))
