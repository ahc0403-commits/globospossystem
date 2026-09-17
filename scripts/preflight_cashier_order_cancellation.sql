DO $$
BEGIN
  IF to_regprocedure('public.cancel_order_pre_start_ready(uuid,uuid,boolean)') IS NULL
     OR to_regprocedure('public.restore_cancelled_order(uuid,uuid)') IS NULL
     OR to_regclass('public.order_cancellation_reversals') IS NULL
     OR to_regclass('public.emergency_floor_direct_items') IS NULL THEN
    RAISE EXCEPTION 'CASHIER_ORDER_CANCELLATION_PREREQUISITES_MISSING';
  END IF;
END;
$$;
