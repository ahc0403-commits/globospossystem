\set ON_ERROR_STOP on

DO $verify$
DECLARE
  v_create regprocedure := to_regprocedure(
    'public.create_store_employee(uuid,text,text,text,text,text,text)'
  );
  v_guard regprocedure := to_regprocedure(
    'public.guard_duplicate_store_employee()'
  );
  v_token regprocedure := to_regprocedure(
    'public.part_timer_employee_name_token(text)'
  );
  v_create_definition text;
  v_guard_definition text;
BEGIN
  IF v_create IS NULL OR v_guard IS NULL OR v_token IS NULL THEN
    RAISE EXCEPTION 'PART_TIMER_EMPLOYEE_ID_FUNCTION_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conrelid = 'public.store_employees'::regclass
      AND conname = 'store_employees_number_check'
      AND pg_get_constraintdef(oid) LIKE '%[A-Z0-9]{2,6}_[A-Za-z]%'
  ) THEN
    RAISE EXCEPTION 'PART_TIMER_EMPLOYEE_ID_CONSTRAINT_INVALID';
  END IF;

  SELECT pg_get_functiondef(v_create)
  INTO v_create_definition
  FROM pg_proc
  WHERE oid = v_create;

  SELECT pg_get_functiondef(v_guard)
  INTO v_guard_definition
  FROM pg_proc
  WHERE oid = v_guard;

  IF v_create_definition NOT LIKE '%left(upper(v_short_code), 2)%'
     OR v_create_definition NOT LIKE '%part_timer_employee_name_token%'
     OR v_create_definition NOT LIKE '%EMPLOYEE_ID_DUPLICATE%'
     OR v_create_definition NOT LIKE '%pg_advisory_xact_lock%' THEN
    RAISE EXCEPTION 'PART_TIMER_EMPLOYEE_ID_CREATE_FUNCTION_INVALID';
  END IF;

  IF v_guard_definition NOT LIKE '%EMPLOYEE_DUPLICATE%'
     OR v_guard_definition LIKE '%employee.is_active = true%'
     OR v_guard_definition LIKE '%employee.is_active = TRUE%' THEN
    RAISE EXCEPTION 'PART_TIMER_EMPLOYEE_ID_DUPLICATE_GUARD_INVALID';
  END IF;

  IF has_function_privilege('anon', v_token, 'EXECUTE')
     OR has_function_privilege('authenticated', v_token, 'EXECUTE')
     OR has_function_privilege('anon', v_guard, 'EXECUTE')
     OR has_function_privilege('authenticated', v_guard, 'EXECUTE') THEN
    RAISE EXCEPTION 'PART_TIMER_EMPLOYEE_ID_HELPER_PRIVILEGE_INVALID';
  END IF;
END
$verify$;

SELECT 'part-timer employee ID verification passed' AS result;
