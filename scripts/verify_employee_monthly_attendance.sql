DO $$
DECLARE
  v_definition text;
BEGIN
  IF to_regprocedure(
    'public.get_employee_attendance_logs(uuid,uuid,timestamp with time zone,timestamp with time zone,integer)'
  ) IS NULL THEN
    RAISE EXCEPTION 'get_employee_attendance_logs is missing';
  END IF;

  SELECT pg_get_functiondef(
    'public.get_employee_attendance_logs(uuid,uuid,timestamp with time zone,timestamp with time zone,integer)'::regprocedure
  ) INTO v_definition;

  IF v_definition NOT LIKE '%log.employee_id = p_employee_id%'
     OR v_definition NOT LIKE '%user_accessible_stores%'
     OR v_definition NOT LIKE '%ATTENDANCE_VIEW_FORBIDDEN%' THEN
    RAISE EXCEPTION 'employee monthly attendance function is incomplete';
  END IF;
END;
$$;

SELECT 'employee monthly attendance verification passed' AS result;
