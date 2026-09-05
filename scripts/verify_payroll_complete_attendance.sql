DO $$
DECLARE
  v_oid oid := to_regprocedure(
    'public.get_payroll_attendance_page(uuid,timestamptz,timestamptz,integer,timestamptz,uuid,text)'
  );
BEGIN
  IF v_oid IS NULL OR NOT EXISTS (
    SELECT 1 FROM pg_proc
    WHERE oid = v_oid AND prosecdef AND provolatile = 's'
      AND prorettype = 'jsonb'::regtype
  ) THEN
    RAISE EXCEPTION 'PAYROLL_ATTENDANCE_FUNCTION_INVALID';
  END IF;
  IF has_function_privilege('anon', v_oid, 'EXECUTE')
     OR has_function_privilege('service_role', v_oid, 'EXECUTE')
     OR NOT has_function_privilege('authenticated', v_oid, 'EXECUTE') THEN
    RAISE EXCEPTION 'PAYROLL_ATTENDANCE_PRIVILEGES_INVALID';
  END IF;
END;
$$;
SELECT 'payroll attendance deployment verification passed' AS result;
