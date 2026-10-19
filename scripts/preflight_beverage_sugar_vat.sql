\set ON_ERROR_STOP on
DO $$
DECLARE signature text;
BEGIN
 FOREACH signature IN ARRAY ARRAY[
 'public.process_payment_without_scoped_promotions(uuid,uuid,numeric,text)',
 'public.process_payment_before_promotion_read_split(uuid,uuid,numeric,text)',
 'public.calculate_order_discountable_total(uuid,uuid)',
 'public.sync_active_order_promotion(uuid,uuid,timestamptz)',
 'public.admin_update_menu_workbook_i18n(uuid,jsonb,jsonb)',
 'public.admin_import_menu_items(uuid,jsonb)',
 'public.direct_order_staff_quote(uuid,uuid,numeric,text)',
 'public.direct_order_approve_payment(uuid,uuid,numeric,text)',
 'public.enqueue_meinvoice_cash_register_job()',
 'public.get_restaurant_daily_sales_exports_by_tax_entity(date)',
 'public.upsert_red_invoice_intake(uuid,uuid,text,text,text,text,text,text,text,text,text,text,text,text)'
 ] LOOP
   IF to_regprocedure(signature) IS NULL THEN RAISE EXCEPTION 'BEVERAGE_VAT_PREREQUISITE_MISSING: %',signature; END IF;
 END LOOP;
 IF to_regclass('public.beverage_vat_20260929_backup') IS NOT NULL THEN
   RAISE EXCEPTION 'BEVERAGE_VAT_ALREADY_APPLIED'; END IF;
END $$;
SELECT 'BEVERAGE_SUGAR_VAT_PREFLIGHT_OK' AS result;
