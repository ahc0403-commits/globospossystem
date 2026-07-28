\set ON_ERROR_STOP on

DO $preflight$
BEGIN
  IF to_regclass('public.attendance_logs') IS NULL
     OR to_regclass('public.store_employees') IS NULL THEN
    RAISE EXCEPTION 'ATTENDANCE_EMPLOYEE_GUARD_TABLE_MISSING';
  END IF;

  IF to_regprocedure(
       'public.get_attendance_logs_with_names(uuid,timestamp with time zone,timestamp with time zone,integer)'
     ) IS NULL
     OR to_regprocedure(
       'public.create_store_employee(uuid,text,text,text,text,text,text)'
     ) IS NULL THEN
    RAISE EXCEPTION 'ATTENDANCE_EMPLOYEE_GUARD_FUNCTION_MISSING';
  END IF;
END
$preflight$;

SELECT 'attendance photo review and duplicate employee guard preflight passed'
  AS result;
