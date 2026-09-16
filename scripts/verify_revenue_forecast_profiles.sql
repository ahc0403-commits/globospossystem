DO $revenue_forecast_verify$
DECLARE
  v_get_oid regprocedure := to_regprocedure(
    'public.get_revenue_forecast_profile(uuid)'
  );
  v_save_oid regprocedure := to_regprocedure(
    'public.save_revenue_forecast_profile(uuid,bigint,text,jsonb)'
  );
BEGIN
  IF to_regclass('public.revenue_forecast_profile_versions') IS NULL THEN
    RAISE EXCEPTION 'REVENUE_FORECAST_VERIFY_TABLE_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_class relation
    JOIN pg_namespace namespace ON namespace.oid = relation.relnamespace
    WHERE namespace.nspname = 'public'
      AND relation.relname = 'revenue_forecast_profile_versions'
      AND relation.relrowsecurity
  ) THEN
    RAISE EXCEPTION 'REVENUE_FORECAST_VERIFY_RLS_DISABLED';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'revenue_forecast_profile_versions'
      AND policyname = 'revenue_forecast_profile_accessible_read'
      AND cmd = 'SELECT'
  ) THEN
    RAISE EXCEPTION 'REVENUE_FORECAST_VERIFY_READ_POLICY_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_indexes
    WHERE schemaname = 'public'
      AND tablename = 'revenue_forecast_profile_versions'
      AND indexname = 'revenue_forecast_profile_current_unique'
      AND indexdef ILIKE '%WHERE (effective_to IS NULL)%'
  ) THEN
    RAISE EXCEPTION 'REVENUE_FORECAST_VERIFY_CURRENT_INDEX_MISSING';
  END IF;

  IF v_get_oid IS NULL OR v_save_oid IS NULL THEN
    RAISE EXCEPTION 'REVENUE_FORECAST_VERIFY_RPC_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_proc
    WHERE oid IN (v_get_oid, v_save_oid)
    HAVING bool_and(prosecdef)
      AND bool_and(
        COALESCE(proconfig, ARRAY[]::text[])
          @> ARRAY['search_path=public, auth, pg_catalog']
      )
      AND count(*) = 2
  ) THEN
    RAISE EXCEPTION 'REVENUE_FORECAST_VERIFY_RPC_SECURITY_INVALID';
  END IF;

  IF NOT has_table_privilege(
    'authenticated',
    'public.revenue_forecast_profile_versions',
    'SELECT'
  ) OR has_table_privilege(
    'authenticated',
    'public.revenue_forecast_profile_versions',
    'INSERT,UPDATE,DELETE'
  ) THEN
    RAISE EXCEPTION 'REVENUE_FORECAST_VERIFY_TABLE_GRANTS_INVALID';
  END IF;

  IF NOT has_function_privilege('authenticated', v_get_oid, 'EXECUTE')
     OR NOT has_function_privilege('authenticated', v_save_oid, 'EXECUTE')
     OR has_function_privilege('anon', v_get_oid, 'EXECUTE')
     OR has_function_privilege('anon', v_save_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'REVENUE_FORECAST_VERIFY_RPC_GRANTS_INVALID';
  END IF;
END;
$revenue_forecast_verify$;
