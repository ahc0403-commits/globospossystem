BEGIN;
SET LOCAL TRANSACTION READ ONLY;
DO $$ BEGIN
 IF has_function_privilege('anon','public.emergency_enrich_start_ready_orders(jsonb)','EXECUTE')
  OR has_function_privilege('authenticated','public.emergency_enrich_start_ready_orders_pre_menu_requests(jsonb)','EXECUTE')
  OR strpos(pg_get_functiondef('public.emergency_enrich_start_ready_orders(jsonb)'::regprocedure),'q.order_id=oi.order_id')=0
  OR public.emergency_enrich_start_ready_orders('[]'::jsonb)<>'[]'::jsonb THEN
  RAISE EXCEPTION 'KDS_MENU_REQUEST_RUNTIME_CONTRACT_FAILED';
 END IF;
END $$;
COMMIT;
SELECT 'KDS_MENU_REQUEST_VERIFICATION=PASS';
