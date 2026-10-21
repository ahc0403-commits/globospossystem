-- Safe both inside the atomic release and as a post-commit read-only verification.
DO $verify$
BEGIN
 IF (SELECT count(*) FROM supabase_migrations.schema_migrations WHERE version BETWEEN '20261021163000' AND '20261022193000' AND version<>'20261021230000')<>35
 OR to_regprocedure('public.admin_preview_store_registration_v1(uuid,uuid,jsonb,text)') IS NULL
 OR to_regprocedure('public.admin_get_store_lifecycle_v1(uuid)') IS NULL
 OR to_regprocedure('public.admin_transition_store_lifecycle_v1(uuid,bigint,text,text,text)') IS NULL
 OR to_regprocedure('public.inventory_lot_workspace_v1(uuid,uuid,uuid)') IS NULL
 OR to_regprocedure('public.procurement_demand_page_v1(uuid,uuid,jsonb)') IS NULL
 OR to_regprocedure('public.admin_get_order_quality_review_v1(uuid,uuid)') IS NULL
 OR to_regprocedure('public.process_payment(uuid,uuid,numeric,text)') IS NULL
 OR to_regprocedure('public.kds_complete_kitchen_batch_v1(uuid,jsonb)') IS NULL THEN
  RAISE EXCEPTION 'LIFECYCLE_RELEASE_API_OR_HISTORY_INCOMPLETE';
 END IF;
 IF EXISTS(SELECT 1 FROM public.restaurants r LEFT JOIN public.store_lifecycle l ON l.restaurant_id=r.id WHERE r.id IN('273b057e-3b69-46e3-93c1-6194c2802849','8bc9eef5-dcd5-46b1-b931-23f77132322c') AND (NOT r.is_active OR l.state IS DISTINCT FROM 'active' OR l.legacy_operational IS DISTINCT FROM true))
 OR EXISTS(SELECT 1 FROM public.store_workflow_configs WHERE restaurant_id IN('273b057e-3b69-46e3-93c1-6194c2802849','8bc9eef5-dcd5-46b1-b931-23f77132322c') AND active_id IS NOT NULL)
 OR EXISTS(SELECT 1 FROM public.users WHERE fixed_account_code='jgbt_tray1' AND is_active)
 OR NOT EXISTS(SELECT 1 FROM public.restaurant_settings WHERE restaurant_id='273b057e-3b69-46e3-93c1-6194c2802849' AND kds_workflow='kitchen_floor')
 OR NOT EXISTS(SELECT 1 FROM public.restaurant_settings WHERE restaurant_id='8bc9eef5-dcd5-46b1-b931-23f77132322c' AND kds_workflow='kitchen_tray_floor') THEN
  RAISE EXCEPTION 'LIFECYCLE_RELEASE_LEGACY_RUNTIME_DRIFT';
 END IF;
 IF NOT EXISTS(SELECT 1 FROM public.emergency_station_assignments a JOIN public.users u ON u.id=a.user_id WHERE u.fixed_account_code='jgbt_floor_1f' AND a.floor_label='2F')
 OR NOT EXISTS(SELECT 1 FROM public.emergency_station_assignments a JOIN public.users u ON u.id=a.user_id WHERE u.fixed_account_code='jgbt_floor_2f' AND a.floor_label='3F') THEN
  RAISE EXCEPTION 'LIFECYCLE_RELEASE_JEONGABOK_FLOOR_DRIFT';
 END IF;
 IF has_function_privilege('anon','public.admin_get_store_lifecycle_v1(uuid)','EXECUTE')
 OR has_table_privilege('authenticated','public.inventory_lots','INSERT')
 OR has_table_privilege('authenticated','public.sales_reporting_batches','UPDATE')
 OR EXISTS(SELECT 1 FROM pg_class WHERE oid IN('public.inventory_lots'::regclass,'public.sales_reporting_batches'::regclass,'public.store_identity_transfers'::regclass) AND NOT relrowsecurity) THEN
  RAISE EXCEPTION 'LIFECYCLE_RELEASE_ACCESS_DRIFT';
 END IF;
END $verify$;
SELECT 'LIFECYCLE_RELEASE_VERIFY=PASS APIs, history, legacy runtime, floor mapping, private ledgers' AS result;
