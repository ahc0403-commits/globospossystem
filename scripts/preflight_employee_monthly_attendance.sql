DO $$
BEGIN
  IF to_regclass('public.attendance_logs') IS NULL
     OR to_regclass('public.store_employees') IS NULL THEN
    RAISE EXCEPTION 'employee monthly attendance prerequisites are missing';
  END IF;
  IF to_regprocedure('public.user_accessible_stores(uuid)') IS NULL THEN
    RAISE EXCEPTION 'user_accessible_stores(uuid) is missing';
  END IF;
END;
$$;

SELECT 'employee monthly attendance preflight passed' AS result;
