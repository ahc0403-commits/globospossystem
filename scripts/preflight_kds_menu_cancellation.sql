DO $$
BEGIN
  IF to_regprocedure('public.cancel_order_item_pre_start_ready(uuid,uuid)') IS NULL
     OR to_regprocedure('public.cashier_cancel_unserved_v1(uuid,uuid,integer,text,uuid)') IS NULL
     OR to_regprocedure('public.restore_cancelled_order_item(uuid,uuid)') IS NULL THEN
    RAISE EXCEPTION 'KDS_MENU_CANCELLATION_PREREQUISITES_MISSING';
  END IF;
END;
$$;
