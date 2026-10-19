\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout='5s';
-- Before accepting new financial activity only. After first use, retain the
-- reader/schema contract for historical mixed tax slices and use a forward fix.
LOCK TABLE public.orders,public.order_items,public.direct_order_request_items IN SHARE ROW EXCLUSIVE MODE;
DO $$
DECLARE saved record;
BEGIN
 IF EXISTS(SELECT 1 FROM public.order_items WHERE vat_breakdown IS NOT NULL)
 OR EXISTS(SELECT 1 FROM public.order_items i JOIN public.menu_items m ON m.id=i.menu_item_id
   WHERE m.vat_category='food' AND i.vat_profile_snapshot @> '[{"rate":10}]'::jsonb)
 OR EXISTS(SELECT 1 FROM public.direct_order_request_items
   WHERE vat_category='food' AND vat_profile_snapshot @> '[{"rate":10}]'::jsonb)
 OR EXISTS(SELECT 1 FROM public.menu_items WHERE beverage_sugar_tax_class<>'not_applicable') THEN
 RAISE EXCEPTION 'BEVERAGE_VAT_FORWARD_FIX_REQUIRED_AFTER_ACTIVATION'; END IF;
 FOR saved IN SELECT * FROM public.beverage_vat_20260929_backup LOOP EXECUTE saved.definition; END LOOP;
END $$;
-- Keep additive columns and saved definitions; no history is deleted.
DROP TRIGGER zzz_order_item_vat_snapshot ON public.order_items;
DROP TRIGGER direct_order_item_vat_snapshot ON public.direct_order_request_items;
REVOKE ALL ON FUNCTION public.admin_create_menu_item_with_tax(uuid,uuid,text,text,text,text,numeric,jsonb,integer,boolean) FROM authenticated;
REVOKE ALL ON FUNCTION public.admin_update_menu_item_with_tax(uuid,text,text,text,text,numeric,jsonb) FROM authenticated;
REVOKE ALL ON FUNCTION public.admin_set_menu_beverage_tax(uuid,jsonb) FROM authenticated;
NOTIFY pgrst,'reload schema';
COMMIT;
