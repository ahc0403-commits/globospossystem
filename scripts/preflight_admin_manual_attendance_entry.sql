DO $$
BEGIN
  IF to_regclass('public.attendance_logs') IS NULL
     OR to_regclass('public.store_employees') IS NULL
     OR to_regclass('public.audit_logs') IS NULL THEN
    RAISE EXCEPTION 'manual attendance prerequisites are missing';
  END IF;
  IF to_regprocedure('public.user_accessible_stores(uuid)') IS NULL THEN
    RAISE EXCEPTION 'user_accessible_stores(uuid) is missing';
  END IF;
END;
$$;

SELECT 'admin manual attendance entry preflight passed' AS result;
