-- Read-only post-apply verification for 20260715000000.
DO $verify$
DECLARE
  v_name text;
  v_options text[];
BEGIN
  FOREACH v_name IN ARRAY ARRAY[
    'store_settings', 'v_store_daily_sales', 'v_store_attendance_summary',
    'v_inventory_status', 'v_brand_kpi', 'v_quality_monitoring',
    'v_qsc_dashboard_summary', 'v_qsc_store_status', 'v_qsc_item_status',
    'v_office_qsc_dashboard', 'v_office_qsc_store_latest',
    'v_office_qsc_issue_queue'
  ] LOOP
    SELECT c.reloptions
    INTO v_options
    FROM pg_catalog.pg_class c
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relname = v_name AND c.relkind = 'v';

    IF NOT COALESCE(v_options, ARRAY[]::text[]) @> ARRAY['security_invoker=true']
       OR has_table_privilege('anon', 'public.' || v_name, 'SELECT') THEN
      RAISE EXCEPTION 'SECURITY_AUDIT_VIEW_VERIFY_FAILED: %', v_name;
    END IF;
  END LOOP;

  IF EXISTS (
    SELECT 1 FROM pg_catalog.pg_policies
    WHERE schemaname = 'public' AND tablename = 'audit_logs'
      AND policyname = 'audit_logs_authenticated_select'
  ) THEN
    RAISE EXCEPTION 'SECURITY_AUDIT_PERMISSIVE_POLICY_REMAINS';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_proc p
    JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'get_user_restaurant_id'
      AND p.prosrc LIKE '%is_active = TRUE%'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_proc p
    JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'is_super_admin'
      AND p.prosrc LIKE '%is_active = TRUE%'
  ) THEN
    RAISE EXCEPTION 'SECURITY_AUDIT_ACTIVE_HELPER_VERIFY_FAILED';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_policies
    WHERE schemaname = 'storage' AND tablename = 'objects'
      AND policyname = 'storage_attendance_scoped'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_policies
    WHERE schemaname = 'storage' AND tablename = 'objects'
      AND policyname = 'storage_qc_scoped'
  ) OR NOT EXISTS (
    SELECT 1 FROM pg_catalog.pg_policies
    WHERE schemaname = 'storage' AND tablename = 'objects'
      AND policyname = 'storage_payment_proofs_scoped'
  ) THEN
    RAISE EXCEPTION 'SECURITY_AUDIT_STORAGE_POLICY_VERIFY_FAILED';
  END IF;
END;
$verify$;
