DO $$
DECLARE v_oid oid := to_regprocedure('public.get_store_revenue_summary(uuid[],date,date)');
BEGIN
  IF v_oid IS NULL OR NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = v_oid
    AND NOT prosecdef AND provolatile = 's' AND prorettype = 'jsonb'::regtype) THEN
    RAISE EXCEPTION 'STORE_REVENUE_FUNCTION_INVALID';
  END IF;
  IF has_function_privilege('anon', v_oid, 'EXECUTE')
    OR has_function_privilege('service_role', v_oid, 'EXECUTE')
    OR NOT has_function_privilege('authenticated', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'STORE_REVENUE_PRIVILEGES_INVALID';
  END IF;
END;
$$;
SELECT 'store revenue summary verification passed' AS result;
