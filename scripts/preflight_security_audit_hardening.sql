-- Read-only preflight for 20260715000000_security_audit_hardening.sql.
DO $preflight$
DECLARE
  v_name text;
BEGIN
  FOREACH v_name IN ARRAY ARRAY[
    'store_settings', 'v_store_daily_sales', 'v_store_attendance_summary',
    'v_inventory_status', 'v_brand_kpi', 'v_quality_monitoring',
    'v_qsc_dashboard_summary', 'v_qsc_store_status', 'v_qsc_item_status',
    'v_office_qsc_dashboard', 'v_office_qsc_store_latest',
    'v_office_qsc_issue_queue'
  ] LOOP
    IF pg_catalog.to_regclass('public.' || v_name) IS NULL THEN
      RAISE EXCEPTION 'SECURITY_AUDIT_PREFLIGHT_VIEW_MISSING: %', v_name;
    END IF;
  END LOOP;

  IF pg_catalog.to_regclass('public.audit_logs') IS NULL
     OR pg_catalog.to_regclass('public.users') IS NULL
     OR pg_catalog.to_regclass('storage.objects') IS NULL THEN
    RAISE EXCEPTION 'SECURITY_AUDIT_PREFLIGHT_BASE_OBJECT_MISSING';
  END IF;

  IF pg_catalog.to_regprocedure('public.get_user_restaurant_id()') IS NULL
     OR pg_catalog.to_regprocedure('public.get_user_role()') IS NULL
     OR pg_catalog.to_regprocedure('public.get_user_store_id()') IS NULL
     OR pg_catalog.to_regprocedure('public.has_any_role(text[])') IS NULL
     OR pg_catalog.to_regprocedure('public.is_super_admin()') IS NULL THEN
    RAISE EXCEPTION 'SECURITY_AUDIT_PREFLIGHT_IDENTITY_HELPER_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'restaurants'
      AND column_name = 'id' AND udt_name = 'uuid'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'restaurants'
      AND column_name = 'name'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'restaurants'
      AND column_name = 'address'
  ) OR NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'restaurants'
      AND column_name = 'is_active' AND udt_name = 'bool'
  ) THEN
    RAISE EXCEPTION 'SECURITY_AUDIT_OFFICE_RESTAURANTS_CONTRACT_MISSING';
  END IF;
END;
$preflight$;
