DO $verify$
DECLARE
  v_signature regprocedure := to_regprocedure(
    'public.get_attendance_logs_with_names(uuid,timestamptz,timestamptz,integer)'
  );
  v_definition text;
BEGIN
  IF v_signature IS NULL THEN
    RAISE EXCEPTION 'ATTENDANCE_NAMES_VERIFY_RPC_MISSING';
  END IF;

  SELECT pg_get_functiondef(v_signature)
  INTO v_definition;

  IF position('ATTENDANCE_VIEW_FORBIDDEN' IN v_definition) = 0
     OR position('user_accessible_stores(auth.uid())' IN v_definition) = 0
     OR position('employee.full_name' IN v_definition) = 0
     OR position('legacy_user.full_name' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'ATTENDANCE_NAMES_VERIFY_RPC_INCOMPLETE';
  END IF;

  IF NOT has_function_privilege(
    'authenticated',
    v_signature,
    'EXECUTE'
  ) OR has_function_privilege(
    'anon',
    v_signature,
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'ATTENDANCE_NAMES_VERIFY_GRANTS_INCOMPLETE';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_indexes
    WHERE schemaname = 'public'
      AND tablename = 'attendance_logs'
      AND indexname = 'attendance_logs_store_logged_at_idx'
  ) THEN
    RAISE EXCEPTION 'ATTENDANCE_NAMES_VERIFY_INDEX_MISSING';
  END IF;
END;
$verify$;

SELECT 'attendance names verification passed' AS result;
