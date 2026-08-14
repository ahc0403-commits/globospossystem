DO $$
DECLARE
  v_definition text;
BEGIN
  IF to_regprocedure(
    'public.admin_record_employee_attendance(uuid,uuid,text,timestamptz,text)'
  ) IS NOT NULL THEN
    RAISE EXCEPTION 'legacy manual attendance RPC still exists';
  END IF;
  IF to_regprocedure(
    'public.admin_record_employee_attendance(uuid,uuid,text,timestamptz,text,text)'
  ) IS NULL THEN
    RAISE EXCEPTION 'PIN-protected manual attendance RPC is missing';
  END IF;

  SELECT pg_get_functiondef(
    'public.admin_record_employee_attendance(uuid,uuid,text,timestamptz,text,text)'::regprocedure
  ) INTO v_definition;
  IF position('verify_discount_manager_pin_or_raise' IN v_definition) = 0
     OR position('p_manager_pin' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'manual attendance RPC does not enforce manager PIN';
  END IF;

  IF NOT has_function_privilege(
    'authenticated',
    'public.admin_record_employee_attendance(uuid,uuid,text,timestamptz,text,text)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'authenticated role cannot execute PIN-protected RPC';
  END IF;
END
$$;

SELECT 'manual attendance manager PIN verification passed' AS result;
