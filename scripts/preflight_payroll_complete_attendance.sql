DO $$
BEGIN
  IF to_regclass('public.attendance_logs') IS NULL
     OR to_regclass('public.store_employees') IS NULL
     OR to_regclass('public.users') IS NULL
     OR to_regprocedure('public.user_accessible_stores(uuid)') IS NULL
     OR to_regprocedure('public.get_attendance_logs_with_names(uuid,timestamptz,timestamptz,integer)') IS NULL THEN
    RAISE EXCEPTION 'PAYROLL_ATTENDANCE_PREREQUISITES_MISSING';
  END IF;
END;
$$;
