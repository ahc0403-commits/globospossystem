DO $$
DECLARE v_oid oid := to_regprocedure(
  'public.get_financial_input_page(text,uuid[],timestamptz,timestamptz,date,date,jsonb,text,integer)');
BEGIN
  IF v_oid IS NULL OR NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = v_oid
    AND NOT prosecdef AND provolatile = 's' AND prorettype = 'jsonb'::regtype) THEN
    RAISE EXCEPTION 'FINANCIAL_INPUT_FUNCTION_INVALID';
  END IF;
  IF has_function_privilege('anon', v_oid, 'EXECUTE')
     OR has_function_privilege('service_role', v_oid, 'EXECUTE')
     OR NOT has_function_privilege('authenticated', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'FINANCIAL_INPUT_PRIVILEGES_INVALID';
  END IF;
END;
$$;
SELECT 'financial input verification passed' AS result;
