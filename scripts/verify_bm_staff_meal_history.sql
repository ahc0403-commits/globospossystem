DO $verify$
DECLARE
  v_function regprocedure := to_regprocedure(
    'public.get_bm_menu_exception_history(uuid,timestamp with time zone,timestamp with time zone,text,boolean,text,timestamp with time zone,integer,integer)'
  );
  v_definition text;
BEGIN
  IF v_function IS NULL THEN
    RAISE EXCEPTION 'BM menu exception history function is missing';
  END IF;

  SELECT pg_get_functiondef(v_function)
  INTO v_definition;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_proc
    WHERE oid = v_function
      AND prosecdef
      AND provolatile = 's'
      AND proconfig @> ARRAY['search_path=pg_catalog, public, auth']::text[]
  ) THEN
    RAISE EXCEPTION
      'BM menu exception history function metadata is invalid';
  END IF;

  IF v_definition NOT LIKE '%v_actor.role <> ''brand_admin''%'
     OR v_definition NOT LIKE '%user_accessible_stores(auth.uid())%'
     OR v_definition NOT LIKE '%order_row.order_purpose = ''staff_meal''%'
     OR v_definition NOT LIKE '%staff_meal_created%' THEN
    RAISE EXCEPTION 'BM role or store scope guard is missing';
  END IF;

  IF EXISTS (
       SELECT 1
       FROM pg_proc function_row
       CROSS JOIN LATERAL aclexplode(
         COALESCE(
           function_row.proacl,
           acldefault('f', function_row.proowner)
         )
       ) privilege_row
       WHERE function_row.oid = v_function
         AND privilege_row.grantee = 0
         AND privilege_row.privilege_type = 'EXECUTE'
     )
     OR has_function_privilege('anon', v_function, 'EXECUTE')
     OR NOT has_function_privilege('authenticated', v_function, 'EXECUTE')
     OR NOT has_function_privilege('service_role', v_function, 'EXECUTE') THEN
    RAISE EXCEPTION 'BM menu exception history function grants are invalid';
  END IF;

  IF to_regclass('public.audit_logs_bm_menu_exception_idx') IS NULL THEN
    RAISE EXCEPTION 'BM menu exception history audit index is missing';
  END IF;

  IF to_regclass('public.orders_bm_staff_meal_history_idx') IS NULL THEN
    RAISE EXCEPTION 'BM staff meal history index is missing';
  END IF;
END;
$verify$;
