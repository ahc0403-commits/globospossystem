\set ON_ERROR_STOP on

DO $verify$
DECLARE
  v_function regprocedure := to_regprocedure(
    'public.record_employee_attendance(uuid,text,text)'
  );
  v_definition text;
  v_config text[];
BEGIN
  IF v_function IS NULL THEN
    RAISE EXCEPTION 'EMPLOYEE_ATTENDANCE_DAILY_GUARD_FUNCTION_MISSING';
  END IF;

  SELECT pg_get_functiondef(v_function), proconfig
  INTO v_definition, v_config
  FROM pg_proc
  WHERE oid = v_function;

  IF v_definition NOT LIKE '%FOR UPDATE%'
     OR v_definition NOT LIKE '%Asia/Ho_Chi_Minh%'
     OR v_definition NOT LIKE '%ATTENDANCE_ALREADY_CLOCKED_IN_TODAY%'
     OR v_definition NOT LIKE '%ATTENDANCE_ALREADY_CLOCKED_OUT_TODAY%'
     OR v_definition NOT LIKE '%ATTENDANCE_CLOCK_IN_REQUIRED%'
     OR v_definition NOT LIKE '%v_last_type IS DISTINCT FROM ''clock_in''%'
     OR NOT ('search_path=public, auth, pg_catalog' = ANY(v_config)) THEN
    RAISE EXCEPTION 'EMPLOYEE_ATTENDANCE_DAILY_GUARD_FUNCTION_INVALID';
  END IF;

  IF has_function_privilege('anon', v_function, 'EXECUTE')
     OR NOT has_function_privilege('authenticated', v_function, 'EXECUTE') THEN
    RAISE EXCEPTION 'EMPLOYEE_ATTENDANCE_DAILY_GUARD_PRIVILEGE_INVALID';
  END IF;
END
$verify$;

SELECT 'employee attendance daily guard verification passed' AS result;
