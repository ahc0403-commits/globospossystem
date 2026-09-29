\set ON_ERROR_STOP on
DO $$
DECLARE result jsonb;
BEGIN
 IF public.menu_effective_vat_rate('food','gt_5')<>10 OR public.menu_effective_vat_rate('food','lte_5')<>8
 OR public.menu_effective_vat_rate('alcohol','not_applicable')<>10 THEN RAISE EXCEPTION 'BEVERAGE_VAT_RATE_INVALID'; END IF;
 result:=public.calculate_item_vat('[{"rate":8,"weight":1},{"rate":10,"weight":1}]',200000,'exclusive',21800);
 IF (result->>'total')::numeric<>196200 OR (result->>'vat')::numeric<>16200 THEN
 RAISE EXCEPTION 'BEVERAGE_VAT_AMOUNT_INVALID'; END IF;
 IF (SELECT count(*) FROM public.beverage_vat_20260929_backup)<>11 THEN
 RAISE EXCEPTION 'BEVERAGE_VAT_BACKUP_INCOMPLETE'; END IF;
 IF position('calculate_item_vat' IN pg_get_functiondef('public.process_payment_without_scoped_promotions(uuid,uuid,numeric,text)'::regprocedure))=0
 OR position('order_item_invoice_tax_lines' IN pg_get_functiondef('public.enqueue_meinvoice_cash_register_job()'::regprocedure))=0
 OR NOT EXISTS(SELECT 1 FROM pg_trigger WHERE tgrelid='public.order_items'::regclass AND tgname='zzz_order_item_vat_snapshot' AND tgenabled='O') THEN
 RAISE EXCEPTION 'BEVERAGE_VAT_WIRING_INVALID'; END IF;
 IF has_function_privilege('anon','public.admin_set_menu_beverage_tax(uuid,jsonb)','EXECUTE')
 OR NOT has_function_privilege('authenticated','public.admin_set_menu_beverage_tax(uuid,jsonb)','EXECUTE') THEN
 RAISE EXCEPTION 'BEVERAGE_VAT_ACL_INVALID'; END IF;
END $$;
SELECT 'BEVERAGE_SUGAR_VAT_VERIFY_OK' AS result;
