DO $$
BEGIN
  IF to_regclass('public.attendance_logs') IS NULL THEN
    RAISE EXCEPTION 'SPLIT_SHIFT_PREFLIGHT_ATTENDANCE_LOGS_MISSING';
  END IF;
  IF to_regclass('public.store_employees') IS NULL THEN
    RAISE EXCEPTION 'SPLIT_SHIFT_PREFLIGHT_STORE_EMPLOYEES_MISSING';
  END IF;
  IF to_regprocedure(
    'public.record_employee_attendance(uuid,text,text)'
  ) IS NULL THEN
    RAISE EXCEPTION 'SPLIT_SHIFT_PREFLIGHT_RPC_MISSING';
  END IF;
  IF to_regprocedure(
    'public.record_employee_attendance_with_photo(uuid,text,text,text)'
  ) IS NULL THEN
    RAISE EXCEPTION 'SPLIT_SHIFT_PREFLIGHT_PHOTO_RPC_MISSING';
  END IF;
END;
$$;
