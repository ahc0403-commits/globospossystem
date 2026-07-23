DO $verify$
DECLARE
  v_signature regprocedure := to_regprocedure(
    'public.record_employee_attendance_with_photo(uuid,text,text,text)'
  );
  v_definition text;
BEGIN
  IF v_signature IS NULL THEN
    RAISE EXCEPTION 'ATTENDANCE_PHOTO_VERIFY_RPC_MISSING';
  END IF;

  SELECT pg_get_functiondef(v_signature)
  INTO v_definition;

  IF v_definition NOT LIKE '%ATTENDANCE_PHOTO_REQUIRED%'
     OR v_definition NOT LIKE '%record_employee_attendance%'
     OR v_definition NOT LIKE '%photo_url = v_photo_url%'
     OR v_definition NOT LIKE '%photo_thumbnail_url = v_photo_url%' THEN
    RAISE EXCEPTION 'ATTENDANCE_PHOTO_VERIFY_RPC_INCOMPLETE';
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
    RAISE EXCEPTION 'ATTENDANCE_PHOTO_VERIFY_GRANTS_INCOMPLETE';
  END IF;
END;
$verify$;
