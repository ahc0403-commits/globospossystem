-- Keep JeonGabok's complete unpaid order visible during additional ordering.
-- Presentation version resets still preserve the existing cart/table handover
-- contract. They must not hide the current party's already served dishes.
-- production-gate: self-verifying
BEGIN;
SET LOCAL lock_timeout='5s';
SET LOCAL statement_timeout='60s';
DO $$ DECLARE definition text; old_text constant text:=
 'WHERE item.created_at >= v_state.visible_from;';
BEGIN
 definition:=pg_get_functiondef('public.qr_get_active_order_pre_start_ready(text)'::regprocedure);
 IF (length(definition)-length(replace(definition,old_text,'')))/length(old_text)<>1 THEN
  RAISE EXCEPTION 'QR_FULL_HISTORY_PREDECESSOR_DRIFT'; END IF;
 EXECUTE replace(definition,old_text,
  'WHERE item.created_at >= v_state.visible_from
     OR public.kds_is_direct_floor_store(v_order.restaurant_id);');
 definition:=pg_get_functiondef('public.qr_get_active_order_pre_start_ready(text)'::regprocedure);
 IF position('OR public.kds_is_direct_floor_store(v_order.restaurant_id)' IN definition)=0
  OR position('order_row.table_id = v_table.table_id' IN definition)=0
  OR position('order_row.restaurant_id = v_table.restaurant_id' IN definition)=0
  OR position('order_row.status IN (''pending'', ''confirmed'', ''serving'')' IN definition)=0
  OR has_function_privilege('anon','public.qr_get_active_order_pre_start_ready(text)','EXECUTE') THEN
  RAISE EXCEPTION 'QR_FULL_HISTORY_SCOPE_VERIFY_FAILED'; END IF;
END $$;
COMMIT;
