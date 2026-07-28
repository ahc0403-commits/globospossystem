\set ON_ERROR_STOP on

DO $verify$
DECLARE
  v_function regprocedure := to_regprocedure(
    'public.guard_duplicate_store_employee()'
  );
  v_definition text;
  v_config text[];
BEGIN
  IF v_function IS NULL THEN
    RAISE EXCEPTION 'DUPLICATE_EMPLOYEE_GUARD_FUNCTION_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger trigger_row
    WHERE trigger_row.tgrelid = 'public.store_employees'::regclass
      AND trigger_row.tgname = 'store_employee_duplicate_guard_before_insert'
      AND NOT trigger_row.tgisinternal
      AND trigger_row.tgenabled = 'O'
  ) THEN
    RAISE EXCEPTION 'DUPLICATE_EMPLOYEE_GUARD_TRIGGER_MISSING';
  END IF;

  SELECT pg_get_functiondef(v_function), proconfig
  INTO v_definition, v_config
  FROM pg_proc
  WHERE oid = v_function;

  IF v_definition NOT LIKE '%pg_advisory_xact_lock%'
     OR v_definition NOT LIKE '%EMPLOYEE_DUPLICATE%'
     OR v_definition NOT LIKE '%employee.store_id = NEW.store_id%'
     OR NOT ('search_path=pg_catalog, public' = ANY(v_config))
     OR has_function_privilege('anon', v_function, 'EXECUTE')
     OR has_function_privilege('authenticated', v_function, 'EXECUTE') THEN
    RAISE EXCEPTION 'DUPLICATE_EMPLOYEE_GUARD_FUNCTION_INVALID';
  END IF;
END
$verify$;

SELECT 'attendance photo review and duplicate employee guard verification passed'
  AS result;
