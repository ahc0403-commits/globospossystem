BEGIN;
SET LOCAL lock_timeout='3s';
DROP FUNCTION public.emergency_enrich_start_ready_orders(jsonb);
ALTER FUNCTION public.emergency_enrich_start_ready_orders_pre_menu_requests(jsonb) RENAME TO emergency_enrich_start_ready_orders;
REVOKE ALL ON FUNCTION public.emergency_enrich_start_ready_orders(jsonb) FROM PUBLIC,anon,authenticated;
COMMIT;
