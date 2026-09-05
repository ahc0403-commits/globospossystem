DO $$
DECLARE
  v_oid oid := to_regprocedure('public.sync_active_order_promotion(uuid,uuid,timestamptz)');
  v_definition text;
BEGIN
  IF v_oid IS NULL OR NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = v_oid
    AND prosecdef AND prorettype = 'public.order_discounts'::regtype
    AND proconfig @> ARRAY['search_path=public, auth']) THEN
    RAISE EXCEPTION 'PROMOTION_ALLOCATION_SYNC_FUNCTION_INVALID';
  END IF;
  SELECT pg_get_functiondef(v_oid) INTO v_definition;
  IF position('OR v_existing_lines IS DISTINCT FROM v_desired_lines' IN v_definition) = 0
    OR position('v_existing_lines IS NOT DISTINCT FROM v_desired_lines' IN v_definition) = 0
    OR position('PROMOTION_ALLOCATION_MISMATCH' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'PROMOTION_ALLOCATION_SYNC_GUARD_MISSING';
  END IF;
  IF has_function_privilege('anon', v_oid, 'EXECUTE')
    OR has_function_privilege('authenticated', v_oid, 'EXECUTE')
    OR NOT has_function_privilege('service_role', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'PROMOTION_ALLOCATION_SYNC_PRIVILEGES_INVALID';
  END IF;
END $$;
