-- Fix cross-tenant data leak: views owned by postgres (BYPASSRLS) granted to
-- authenticated without security_invoker = true expose all stores' data.
-- Pattern reference: 299_deliberry_integration_security_closure.sql

-- Office connection views (from 20260405000003, redefined in 20260405000012)
ALTER VIEW public.v_store_daily_sales SET (security_invoker = true);
ALTER VIEW public.v_store_attendance_summary SET (security_invoker = true);
ALTER VIEW public.v_inventory_status SET (security_invoker = true);
ALTER VIEW public.v_brand_kpi SET (security_invoker = true);

-- v_quality_monitoring: created in 20260405000003, redefined in 20260507000002
ALTER VIEW public.v_quality_monitoring SET (security_invoker = true);

-- QSC v2 views (from 20260507000002) — granted to authenticated, no security_invoker
ALTER VIEW public.v_qsc_dashboard_summary SET (security_invoker = true);
ALTER VIEW public.v_qsc_store_status SET (security_invoker = true);
ALTER VIEW public.v_qsc_item_status SET (security_invoker = true);

-- QSC v2 Office read-model wrapper views (from 20260507000006)
-- A secured inner view does not protect an owner-executed outer view.
ALTER VIEW public.v_office_qsc_dashboard SET (security_invoker = true);
ALTER VIEW public.v_office_qsc_store_latest SET (security_invoker = true);
ALTER VIEW public.v_office_qsc_issue_queue SET (security_invoker = true);

-- Office POS sales views — if 20260604001000 was already applied, these exist
-- without security_invoker. The uncommitted 20260609000000 is patched in-place.
-- This handles the case where 20260604001000 was applied but 20260609000000 was not.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.views
    WHERE table_schema = 'public' AND table_name = 'v_office_pos_sales_events'
  ) THEN
    ALTER VIEW public.v_office_pos_sales_events SET (security_invoker = true);
  END IF;
  IF EXISTS (
    SELECT 1 FROM information_schema.views
    WHERE table_schema = 'public' AND table_name = 'v_office_pos_sales_bucket_summary'
  ) THEN
    ALTER VIEW public.v_office_pos_sales_bucket_summary SET (security_invoker = true);
  END IF;
END $$;

SELECT pg_notify('pgrst', 'reload schema');

-- Validation: verify no authenticated-granted public views remain without security_invoker.
-- Run manually after applying:
--
-- SELECT c.relname AS view_name,
--        pg_catalog.obj_description(c.oid) AS comment,
--        COALESCE((SELECT option_value FROM pg_options_to_table(c.reloptions)
--                  WHERE option_name = 'security_invoker'), 'false') AS security_invoker
-- FROM pg_class c
-- JOIN pg_namespace n ON n.oid = c.relnamespace
-- WHERE n.nspname = 'public'
--   AND c.relkind = 'v'
--   AND EXISTS (
--     SELECT 1 FROM information_schema.role_table_grants g
--     WHERE g.table_schema = 'public'
--       AND g.table_name = c.relname
--       AND g.grantee = 'authenticated'
--       AND g.privilege_type = 'SELECT'
--   )
-- ORDER BY c.relname;
