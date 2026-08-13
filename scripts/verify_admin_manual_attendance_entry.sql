DO $$
DECLARE
  v_definition text;
BEGIN
  IF to_regprocedure(
    'public.admin_record_employee_attendance(uuid,uuid,text,timestamp with time zone,text)'
  ) IS NULL THEN
    RAISE EXCEPTION 'admin_record_employee_attendance is missing';
  END IF;

  SELECT pg_get_functiondef(
    'public.admin_record_employee_attendance(uuid,uuid,text,timestamp with time zone,text)'::regprocedure
  ) INTO v_definition;

  IF v_definition NOT LIKE '%attendance_manual_entry%'
     OR v_definition NOT LIKE '%ATTENDANCE_MANUAL_SEQUENCE_INVALID%'
     OR v_definition NOT LIKE '%user_accessible_stores%' THEN
    RAISE EXCEPTION 'manual attendance function is incomplete';
  END IF;
END;
$$;

SELECT 'admin manual attendance entry verification passed' AS result;
