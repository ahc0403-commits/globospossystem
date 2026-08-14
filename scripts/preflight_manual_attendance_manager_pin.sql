DO $$
BEGIN
  IF to_regprocedure(
    'public.admin_record_employee_attendance(uuid,uuid,text,timestamptz,text)'
  ) IS NULL THEN
    RAISE EXCEPTION 'manual attendance RPC is missing';
  END IF;
  IF to_regprocedure(
    'public.verify_discount_manager_pin_or_raise(uuid,text,text)'
  ) IS NULL THEN
    RAISE EXCEPTION 'manager PIN verification RPC is missing';
  END IF;
END
$$;

SELECT 'manual attendance manager PIN preflight passed' AS result;
