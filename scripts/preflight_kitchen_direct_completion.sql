DO $preflight$
BEGIN
  IF to_regclass('public.orders') IS NULL
     OR to_regclass('public.order_items') IS NULL THEN
    RAISE EXCEPTION 'KITCHEN_DIRECT_COMPLETION_PREFLIGHT_ORDER_TABLES_MISSING';
  END IF;
  IF to_regprocedure('public.update_order_item_status(uuid,uuid,text)') IS NULL THEN
    RAISE EXCEPTION 'KITCHEN_DIRECT_COMPLETION_PREFLIGHT_ITEM_RPC_MISSING';
  END IF;
  IF to_regprocedure('public.recalc_order_status(uuid)') IS NULL THEN
    RAISE EXCEPTION 'KITCHEN_DIRECT_COMPLETION_PREFLIGHT_RECALC_MISSING';
  END IF;
  IF to_regprocedure('public.enqueue_print_jobs(uuid,text[],jsonb,text)') IS NULL THEN
    RAISE EXCEPTION 'KITCHEN_DIRECT_COMPLETION_PREFLIGHT_PRINT_QUEUE_MISSING';
  END IF;
END;
$preflight$;
