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
  'capture_menu_option_batch','direct_order_deduct_combo_stock','process_payment_without_scoped_promotions',
  'process_payment_before_promotion_read_split',
  'admin_create_menu_item_with_options','admin_update_menu_item_with_options','menu_size_price_sync_batch',
  'validate_menu_option_batch','create_order_pre_takeout_core','add_items_to_order_pre_takeout_core',
  'qr_place_order_pre_takeout_core','qr_place_order','qr_place_order_before_daily_reset','qr_place_order_pre_takeout_availability',
  'snapshot_order_item_takeout','direct_order_enrich_translations','direct_order_public_status_v11',
  'cashier_item_progress','cashier_restore_item_quantity','cashier_move_order_items','cashier_partial_progress_sync',
  'emergency_enqueue_push','kds_apply_station_progress_batch_v1','get_emergency_station_snapshot','get_kds_bootstrap_v2','get_kds_changes_v2','kds_can_access_topic',
  'direct_order_staff_detail_v8','direct_order_quote_preview_core','direct_order_staff_quote_before_final_amount','direct_order_lock_combo_stock')),
 'unrelated function changed';
 ASSERT (SELECT count(*)=2 FROM operating_test.function_baseline b
 JOIN pg_proc p ON p.oid=to_regprocedure(b.signature)
 WHERE p.proname='get_pos_daily_sales_summary' AND md5(pg_get_functiondef(p.oid))=b.hash),
 'current sales reporting overloads missing or changed';
END $$;
SELECT 'WORKFLOW_UPGRADE_FUNCTION_AND_SALES_CONTRACT=PASS';
