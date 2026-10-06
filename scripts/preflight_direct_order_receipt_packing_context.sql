BEGIN READ ONLY;
DO $preflight$
BEGIN
  IF to_regprocedure('public.direct_order_fulfillment_context(uuid)') IS NULL
    OR to_regprocedure('public.direct_order_require_actor(uuid,text[])') IS NULL
    OR NOT EXISTS (SELECT 1 FROM pg_trigger
      WHERE tgrelid='public.print_jobs'::regclass
        AND tgname='zz_direct_order_enrich_print_fulfillment' AND tgenabled='O')
    OR NOT EXISTS (SELECT 1 FROM information_schema.columns
      WHERE table_schema='public' AND table_name='digital_receipts'
        AND column_name='combined_payment_group_id')
    OR NOT EXISTS (SELECT 1 FROM information_schema.columns
      WHERE table_schema='public' AND table_name='direct_order_requests'
        AND column_name='diner_count') THEN
    RAISE EXCEPTION 'DIRECT_ORDER_PACKING_PREDECESSOR_REQUIRED';
  END IF;
END;
$preflight$;
SELECT 'DIRECT_ORDER_PACKING_PREFLIGHT=PASS';
ROLLBACK;
