\set ON_ERROR_STOP on

DO $preflight$
BEGIN
  IF to_regprocedure(
    'public.create_store_employee(uuid,text,text,text,text,text,text)'
  ) IS NULL THEN
    RAISE EXCEPTION 'INACTIVE_EMPLOYEE_RECREATE_CREATE_FUNCTION_MISSING';
  END IF;

  IF to_regprocedure('public.guard_duplicate_store_employee()') IS NULL THEN
    RAISE EXCEPTION 'INACTIVE_EMPLOYEE_RECREATE_GUARD_FUNCTION_MISSING';
  END IF;

  IF to_regprocedure('public.part_timer_employee_name_token(text)') IS NULL THEN
    RAISE EXCEPTION 'INACTIVE_EMPLOYEE_RECREATE_TOKEN_FUNCTION_MISSING';
  END IF;

  IF to_regclass('public.store_employees') IS NULL
     OR NOT EXISTS (
       SELECT 1
       FROM pg_attribute
       WHERE attrelid = 'public.store_employees'::regclass
         AND attname = 'is_active'
         AND NOT attisdropped
     ) THEN
    RAISE EXCEPTION 'INACTIVE_EMPLOYEE_RECREATE_SCHEMA_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger
    WHERE tgrelid = 'public.store_employees'::regclass
      AND tgname = 'store_employee_duplicate_guard_before_insert'
      AND NOT tgisinternal
  ) THEN
    RAISE EXCEPTION 'INACTIVE_EMPLOYEE_RECREATE_TRIGGER_MISSING';
  END IF;
END
$preflight$;

SELECT 'inactive employee recreation preflight passed' AS result;
