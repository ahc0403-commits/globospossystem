DO $$
DECLARE
  v_definition text;
BEGIN
  SELECT pg_get_functiondef(
    'public.record_employee_attendance(uuid,text,text)'::regprocedure
  ) INTO v_definition;

  IF position('FOR UPDATE' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'SPLIT_SHIFT_VERIFY_ROW_LOCK_MISSING';
  END IF;
  IF position('ATTENDANCE_ALREADY_CLOCKED_IN' IN v_definition) = 0
     OR position('ATTENDANCE_ALREADY_CLOCKED_OUT' IN v_definition) = 0
     OR position('ATTENDANCE_CLOCK_IN_REQUIRED' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'SPLIT_SHIFT_VERIFY_EVENT_GUARD_MISSING';
  END IF;
  IF position('v_has_clock_in_today' IN v_definition) > 0
     OR position('ATTENDANCE_ALREADY_CLOCKED_IN_TODAY' IN v_definition) > 0 THEN
    RAISE EXCEPTION 'SPLIT_SHIFT_VERIFY_DAILY_GUARD_REMAINS';
  END IF;
  IF NOT has_function_privilege(
    'authenticated',
    'public.record_employee_attendance(uuid,text,text)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'SPLIT_SHIFT_VERIFY_AUTHENTICATED_EXECUTE_MISSING';
  END IF;
END;
$$;
