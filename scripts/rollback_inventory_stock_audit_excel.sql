-- Keep existing audit history and its snapshots when reverting the application.
BEGIN;
DROP FUNCTION IF EXISTS public.save_inventory_stock_audit_v2(uuid,uuid,integer,jsonb,boolean,text);
DROP FUNCTION IF EXISTS public.prepare_inventory_stock_audit(uuid,uuid);
DROP FUNCTION IF EXISTS public.cancel_inventory_stock_audit(uuid,uuid,integer);
NOTIFY pgrst,'reload schema';
COMMIT;
