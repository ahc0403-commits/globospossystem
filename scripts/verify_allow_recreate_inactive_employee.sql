\set ON_ERROR_STOP on

DO $verify$
DECLARE
  v_create regprocedure := to_regprocedure(
    'public.create_store_employee(uuid,text,text,text,text,text,text)'
  );
  v_guard regprocedure := to_regprocedure(
    'public.guard_duplicate_store_employee()'
  );
  v_create_definition text;
  v_guard_definition text;
BEGIN
  IF v_create IS NULL OR v_guard IS NULL THEN
    RAISE EXCEPTION 'INACTIVE_EMPLOYEE_RECREATE_FUNCTION_MISSING';
  END IF;

  SELECT lower(pg_get_functiondef(v_create))
  INTO v_create_definition;
  SELECT lower(pg_get_functiondef(v_guard))
  INTO v_guard_definition;

  IF v_create_definition NOT LIKE '%v_employee_number_base%'
     OR v_create_definition NOT LIKE '%v_suffix%'
     OR v_create_definition NOT LIKE '%employee.is_active = true%'
     OR v_create_definition NOT LIKE '%employee_id_duplicate%'
     OR v_create_definition NOT LIKE '%pg_advisory_xact_lock%' THEN
    RAISE EXCEPTION 'INACTIVE_EMPLOYEE_RECREATE_CREATE_FUNCTION_INVALID';
  END IF;

  IF v_guard_definition NOT LIKE '%employee.is_active = true%'
     OR v_guard_definition NOT LIKE '%employee_duplicate%'
     OR v_guard_definition NOT LIKE '%pg_advisory_xact_lock%' THEN
    RAISE EXCEPTION 'INACTIVE_EMPLOYEE_RECREATE_GUARD_INVALID';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger
    WHERE tgrelid = 'public.store_employees'::regclass
      AND tgname = 'store_employee_duplicate_guard_before_insert'
      AND tgfoid = v_guard::oid
      AND NOT tgisinternal
  ) THEN
    RAISE EXCEPTION 'INACTIVE_EMPLOYEE_RECREATE_TRIGGER_INVALID';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc WHERE oid = v_create AND prosecdef
  ) OR EXISTS (
    SELECT 1 FROM pg_proc WHERE oid = v_guard AND prosecdef
  ) THEN
    RAISE EXCEPTION 'INACTIVE_EMPLOYEE_RECREATE_SECURITY_MODE_INVALID';
  END IF;

  IF has_function_privilege('anon', v_create, 'EXECUTE')
     OR NOT has_function_privilege('authenticated', v_create, 'EXECUTE')
     OR has_function_privilege('anon', v_guard, 'EXECUTE')
     OR has_function_privilege('authenticated', v_guard, 'EXECUTE') THEN
    RAISE EXCEPTION 'INACTIVE_EMPLOYEE_RECREATE_PRIVILEGE_INVALID';
  END IF;
END
$verify$;

SELECT 'inactive employee recreation verification passed' AS result;
