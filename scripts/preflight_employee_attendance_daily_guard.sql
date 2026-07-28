\set ON_ERROR_STOP on

DO $preflight$
BEGIN
  IF to_regclass('public.attendance_logs') IS NULL
     OR to_regclass('public.store_employees') IS NULL
     OR to_regclass('public.users') IS NULL THEN
    RAISE EXCEPTION 'EMPLOYEE_ATTENDANCE_DAILY_GUARD_TABLE_MISSING';
  END IF;

  IF to_regprocedure(
       'public.record_employee_attendance(uuid,text,text)'
     ) IS NULL
     OR to_regprocedure(
       'public.record_employee_attendance_with_photo(uuid,text,text,text)'
     ) IS NULL
     OR to_regprocedure('public.user_accessible_stores(uuid)') IS NULL THEN
    RAISE EXCEPTION 'EMPLOYEE_ATTENDANCE_DAILY_GUARD_FUNCTION_MISSING';
  END IF;
END
$preflight$;

SELECT 'employee attendance daily guard preflight passed' AS result;
