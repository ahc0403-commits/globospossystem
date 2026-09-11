\set ON_ERROR_STOP on
BEGIN READ ONLY;
-- Run before rollout on the production connection. This report never changes
-- orders, accounts, permissions, or inventory and contains no credentials.
SELECT r.id AS store_id,r.name,r.brand_id,r.tax_entity_id,
  count(DISTINCT u.id) FILTER (WHERE u.role='inventory_orderer') AS orderer_accounts,
  count(DISTINCT u.id) FILTER (WHERE u.role IN ('admin','store_admin')) AS store_approver_accounts,
  count(DISTINCT u.id) FILTER (WHERE u.role IN ('brand_admin','super_admin')) AS brand_approver_accounts,
  count(DISTINCT u.id) FILTER (WHERE u.role='inventory_accounting') AS accounting_accounts
FROM public.restaurants r
LEFT JOIN public.users u ON u.is_active AND (
  u.role='super_admin' OR COALESCE(u.primary_store_id,u.restaurant_id)=r.id OR EXISTS (
    SELECT 1 FROM public.user_accessible_stores(u.auth_id) s(store_id) WHERE s.store_id=r.id))
WHERE r.is_active
GROUP BY r.id,r.name,r.brand_id,r.tax_entity_id ORDER BY r.name;

SELECT restaurant_id,status,count(*) AS order_count,
  count(*) FILTER (WHERE created_by=store_approved_by) AS creator_store_approved,
  count(*) FILTER (WHERE created_by=brand_approved_by) AS creator_brand_approved,
  min(created_at) AS oldest_order
FROM public.inventory_purchase_orders GROUP BY restaurant_id,status ORDER BY restaurant_id,status;
SELECT restaurant_id,status,count(*) AS receipt_count,
  count(*) FILTER (WHERE statement_storage_path IS NULL) AS missing_attachment
FROM public.inventory_receipts GROUP BY restaurant_id,status ORDER BY restaurant_id,status;

SELECT p.oid::regprocedure AS function_signature,
  md5(pg_get_functiondef(p.oid)) AS definition_hash
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public' AND p.proname IN (
  'can_access_inventory_purchase_store','can_access_inventory_workflow','can_create_inventory_purchase_order',
  'can_verify_inventory_receipt','store_decide_inventory_purchase_order','brand_decide_inventory_purchase_order',
  'verify_inventory_receipt','submit_inventory_receipt_batch');
SELECT schemaname,tablename,policyname,cmd,qual,with_check FROM pg_policies
WHERE tablename IN ('inventory_supplier_items','inventory_supplier_item_price_history',
  'inventory_purchase_orders','inventory_purchase_order_lines','inventory_receipts','pos_live_events');
SELECT schemaname,tablename FROM pg_publication_tables WHERE pubname='supabase_realtime' AND tablename='pos_live_events';
ROLLBACK;
