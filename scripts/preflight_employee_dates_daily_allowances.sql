\set ON_ERROR_STOP on

DO $preflight$
BEGIN
  IF to_regclass('public.store_employees') IS NULL
     OR to_regclass('public.attendance_logs') IS NULL
     OR to_regclass('public.inventory_items') IS NULL
     OR to_regclass('public.employee_hourly_pay_rules') IS NULL THEN
    RAISE EXCEPTION 'EMPLOYEE_DATES_ALLOWANCES_DEPENDENCY_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'attendance_logs'
      AND column_name = 'employee_id'
      AND data_type = 'uuid'
  ) THEN
    RAISE EXCEPTION 'EMPLOYEE_ATTENDANCE_ID_DEPENDENCY_MISSING';
  END IF;

  IF to_regprocedure(
       'public.create_store_employee(uuid,text,text,text,text,text,text)'
     ) IS NULL
     OR to_regprocedure(
       'public.update_store_employee(uuid,uuid,text,text,text,text,text,text)'
     ) IS NULL
     OR to_regprocedure(
       'public.save_photo_objet_daily_inventory_item(uuid,uuid,text,numeric,date,text)'
     ) IS NULL
     OR to_regprocedure('public.require_workforce_manager(uuid)') IS NULL THEN
    RAISE EXCEPTION 'EMPLOYEE_DATES_ALLOWANCES_FUNCTION_DEPENDENCY_MISSING';
  END IF;
END;
$preflight$;

SELECT 'employee dates, daily allowances, and decimal inventory preflight passed' AS result;
