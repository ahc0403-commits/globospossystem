DO $final$
BEGIN
 IF to_regclass('public.tax_entity_collection_accounts') IS NULL OR to_regclass('public.menu_invoice_profiles') IS NULL
 OR to_regclass('public.meinvoice_job_snapshot_versions') IS NULL THEN RAISE EXCEPTION 'CORPORATE_RELEASE_TABLES_MISSING'; END IF;
 IF public.misa_payment_code_for_methods(ARRAY['BANKTRANSFER'])<>'CK' OR public.misa_payment_code_for_methods(ARRAY['CASH','BANKTRANSFER'])<>'TM/CK'
 OR public.misa_payment_code_for_methods(ARRAY['MOMO'])<>'Ví điện tử' OR public.misa_payment_kind_for_methods(ARRAY['VNPAY'])<>'GATEWAY'
 OR public.misa_payment_kind_for_methods(ARRAY['VOUCHER'])<>'VOUCHER' OR public.misa_payment_kind_for_methods(ARRAY['CREDITSALE'])<>'CREDITSALE'
 OR public.misa_payment_code_for_methods(ARRAY['QR'])<>'UNMAPPED' THEN RAISE EXCEPTION 'CORPORATE_RELEASE_PAYMENT_CONTRACT_CHANGED'; END IF;
 IF has_function_privilege('anon','public.get_store_collection_bank(uuid)','EXECUTE')
 OR has_function_privilege('anon','public.get_pos_daily_sales_summary(date)','EXECUTE')
 OR has_function_privilege('anon','public.get_pos_daily_sales_export_page(date,uuid,text,timestamptz,text,integer)','EXECUTE')
 OR has_function_privilege('anon','public.refresh_meinvoice_export_snapshots(date,uuid,uuid[])','EXECUTE') THEN RAISE EXCEPTION 'CORPORATE_RELEASE_ANONYMOUS_ACCESS'; END IF;
 RAISE NOTICE 'CORPORATE_SALES_CONTACTS_ATOMIC_RELEASE=PASS';
END $final$;
COMMIT;
