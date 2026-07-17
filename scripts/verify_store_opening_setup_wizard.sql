DO $$
DECLARE
  v_signature text;
BEGIN
  IF to_regclass('public.printer_destinations_active_route_unique') IS NULL THEN
    RAISE EXCEPTION 'STORE_SETUP_VERIFY_UNIQUE_INDEX_MISSING';
  END IF;

  FOREACH v_signature IN ARRAY ARRAY[
    'public.admin_validate_store_opening_config(uuid,jsonb,jsonb)',
    'public.admin_apply_store_opening_config(uuid,jsonb,jsonb)',
    'public.admin_get_store_opening_readiness(uuid)'
  ] LOOP
    IF to_regprocedure(v_signature) IS NULL THEN
      RAISE EXCEPTION 'STORE_SETUP_VERIFY_RPC_MISSING:%', v_signature;
    END IF;
  END LOOP;

  IF EXISTS (
    SELECT 1
    FROM public.printer_destinations
    WHERE is_active = true
    GROUP BY restaurant_id, lower(btrim(purpose)),
      COALESCE(upper(btrim(floor_label)), '')
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'STORE_SETUP_VERIFY_DUPLICATE_ACTIVE_ROUTE';
  END IF;

  IF has_function_privilege('anon',
       'public.admin_validate_store_opening_config(uuid,jsonb,jsonb)', 'EXECUTE')
     OR has_function_privilege('anon',
       'public.admin_apply_store_opening_config(uuid,jsonb,jsonb)', 'EXECUTE')
     OR has_function_privilege('anon',
       'public.admin_get_store_opening_readiness(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'STORE_SETUP_VERIFY_ANON_EXECUTE_PRESENT';
  END IF;

  IF NOT has_function_privilege('authenticated',
       'public.admin_validate_store_opening_config(uuid,jsonb,jsonb)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated',
       'public.admin_apply_store_opening_config(uuid,jsonb,jsonb)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated',
       'public.admin_get_store_opening_readiness(uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'STORE_SETUP_VERIFY_AUTHENTICATED_EXECUTE_MISSING';
  END IF;
END;
$$;

SELECT 'STORE_SETUP_VERIFY_OK' AS result;
