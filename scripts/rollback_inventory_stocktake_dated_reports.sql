-- Preserve completed counts, their effective dates and reports. Revert web to
-- v1 before using this emergency rollback; quantities are never reset.
BEGIN;
DROP FUNCTION public.save_inventory_stock_audit_v2(uuid,uuid,integer,jsonb,boolean,text);
ALTER FUNCTION public.save_inventory_stock_audit_v2_legacy_impl(uuid,uuid,integer,jsonb,boolean,text) RENAME TO save_inventory_stock_audit_v2;
GRANT EXECUTE ON FUNCTION public.save_inventory_stock_audit_v2(uuid,uuid,integer,jsonb,boolean,text) TO authenticated,service_role;
DROP TRIGGER IF EXISTS inventory_stock_movement_annotation ON public.inventory_transactions;
DROP TRIGGER IF EXISTS inventory_stock_movement_capture ON public.inventory_items;
DROP FUNCTION IF EXISTS public.save_inventory_stock_audit_v3(uuid,uuid,integer,jsonb,boolean,text,text,boolean,boolean);
DROP FUNCTION IF EXISTS public.preview_inventory_stock_audit_v3(uuid,uuid,jsonb,boolean,boolean);
DROP FUNCTION IF EXISTS public.prepare_inventory_stock_audit_v2(uuid,date,timestamptz);
-- Retained read functions/tables provide the existing report provenance.
NOTIFY pgrst,'reload schema';
COMMIT;
