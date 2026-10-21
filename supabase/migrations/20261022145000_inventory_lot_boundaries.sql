-- Prevent receiving and shortage transfer from independently claiming a held
-- balance. PO locks serialize all three paths; no stock changes on rejection.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout='5s';
CREATE FUNCTION public.inventory_assert_held_order_balance_v1(p_orders uuid[]) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_catalog AS $$
BEGIN
 IF EXISTS(WITH lines AS MATERIALIZED(SELECT id,ordered_quantity_base,cancelled_quantity_base FROM inventory_purchase_order_lines WHERE purchase_order_id=ANY(p_orders)),
 accepted AS(SELECT rl.purchase_order_line_id,sum(rl.accepted_quantity_base) qty FROM inventory_receipt_lines rl JOIN inventory_receipts r ON r.id=rl.receipt_id AND r.status='confirmed' JOIN lines l ON l.id=rl.purchase_order_line_id GROUP BY rl.purchase_order_line_id),
 reserved AS(SELECT original_order_line_id,sum(quantity_base) qty FROM procurement_shortage_allocations a JOIN lines l ON l.id=a.original_order_line_id WHERE status='reserved' GROUP BY original_order_line_id)
 SELECT 1 FROM lines l JOIN inventory_held_by_order_line_v1(ARRAY(SELECT id FROM lines))h ON h.order_line_id=l.id LEFT JOIN accepted a ON a.purchase_order_line_id=l.id LEFT JOIN reserved r ON r.original_order_line_id=l.id
 WHERE coalesce(a.qty,0)+coalesce(r.qty,0)+h.quantity_base>l.ordered_quantity_base-l.cancelled_quantity_base) THEN RAISE EXCEPTION 'INVENTORY_HELD_ORDER_BALANCE_CONFLICT'; END IF;
END $$;
DO $$ DECLARE d text; BEGIN
 d:=pg_get_functiondef('public.inventory_capture_quarantine_v1()'::regprocedure);
 d:=replace(d,E'\n RETURN NULL;', E'\n PERFORM inventory_assert_held_order_balance_v1(ARRAY(SELECT DISTINCT purchase_order_id FROM new_lot_receipts WHERE status=''confirmed'')); RETURN NULL;'); EXECUTE d;
 d:=pg_get_functiondef('public.store_capture_order_quality_v1()'::regprocedure);
 d:=replace(d,E'\n RETURN NULL;', E'\n IF EXISTS(SELECT 1 FROM procurement_order_quality q JOIN procurement_quality_profiles profile ON profile.id=q.profile_id JOIN inventory_purchase_order_lines l ON l.id=q.order_line_id JOIN inventory_products p ON p.id=l.product_id LEFT JOIN inventory_lot_tracking t ON t.ingredient_id=p.inventory_item_id WHERE q.order_line_id=ANY(ids) AND profile.criteria->>''lot_required''=''true'' AND t.ingredient_id IS NULL) THEN RAISE EXCEPTION ''INVENTORY_OPENING_LOT_COUNT_REQUIRED''; END IF; RETURN NULL;'); EXECUTE d;
END $$;
REVOKE ALL ON FUNCTION public.inventory_assert_held_order_balance_v1(uuid[]) FROM PUBLIC,anon,authenticated,service_role;
COMMIT;
