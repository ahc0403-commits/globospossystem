\set ON_ERROR_STOP on

DO $preflight$
BEGIN
  IF to_regclass('public.store_employees') IS NULL
     OR to_regclass('public.store_employee_number_sequences') IS NULL
     OR to_regclass('public.restaurants') IS NULL THEN
    RAISE EXCEPTION 'PART_TIMER_EMPLOYEE_ID_TABLE_MISSING';
  END IF;

  IF to_regprocedure(
       'public.create_store_employee(uuid,text,text,text,text,text,text)'
     ) IS NULL
     OR to_regprocedure('public.guard_duplicate_store_employee()') IS NULL
     OR to_regprocedure('public.require_workforce_manager(uuid)') IS NULL THEN
    RAISE EXCEPTION 'PART_TIMER_EMPLOYEE_ID_FUNCTION_MISSING';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.store_employees
    WHERE employee_number !~ '^[A-Z0-9]{2,6}[1-9][0-9]*$'
      AND employee_number !~ '^[A-Z0-9]{2,6}_[A-Za-z][A-Za-z0-9_]{0,39}$'
  ) THEN
    RAISE EXCEPTION 'PART_TIMER_EMPLOYEE_ID_EXISTING_NUMBER_INVALID';
  END IF;
END
$preflight$;

SELECT 'part-timer employee ID preflight passed' AS result;
