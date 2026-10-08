BEGIN;
SET LOCAL TRANSACTION READ ONLY;
DO $$ BEGIN
 IF to_regprocedure('public.emergency_enrich_start_ready_orders(jsonb)') IS NULL
  OR to_regprocedure('public.emergency_enrich_start_ready_orders_pre_menu_requests(jsonb)') IS NOT NULL
  OR NOT EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='order_items' AND column_name='notes')
  OR NOT EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='emergency_order_queue' AND column_name='order_id') THEN
  RAISE EXCEPTION 'KDS_MENU_REQUEST_PREFLIGHT_FAILED';
 END IF;
END $$;
COMMIT;
SELECT 'KDS_MENU_REQUEST_PREFLIGHT=PASS';
