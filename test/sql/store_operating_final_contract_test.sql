DO $$ BEGIN
 ASSERT NOT EXISTS(SELECT 1 FROM operating_test.function_baseline b
 LEFT JOIN pg_proc p ON p.oid=to_regprocedure(b.signature)
 WHERE p.oid IS NULL OR p.proacl::text IS DISTINCT FROM b.acl
 OR p.proowner<>b.owner_id OR p.prosecdef<>b.security_definer OR p.proconfig IS DISTINCT FROM b.config),
 'existing function access contract changed';
 ASSERT NOT EXISTS(SELECT 1 FROM operating_test.function_baseline b
 JOIN pg_proc p ON p.oid=to_regprocedure(b.signature)
 WHERE md5(pg_get_functiondef(p.oid))<>b.hash AND p.proname NOT IN (
  'direct_order_prepare_combo_items','direct_order_public_submit','direct_order_public_submit_v2',
  'direct_order_approve_payment','direct_order_approve_payment_before_combo',
  'snapshot_direct_order_item_vat','snapshot_order_item_combo_components','snapshot_order_item_vat',
  'capture_menu_option_batch','direct_order_deduct_combo_stock','process_payment_without_scoped_promotions')),
 'unrelated function changed';
 ASSERT (SELECT count(*)=2 FROM operating_test.function_baseline b
 JOIN pg_proc p ON p.oid=to_regprocedure(b.signature)
 WHERE p.proname='get_pos_daily_sales_summary' AND md5(pg_get_functiondef(p.oid))=b.hash),
 'current sales reporting overloads missing or changed';
END $$;
SELECT 'OPERATING_FINAL_FUNCTION_AND_SALES_CONTRACT=PASS';
