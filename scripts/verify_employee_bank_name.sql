DO $verify$
DECLARE
  v_definition text;
  v_result text;
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'store_employees'
      AND column_name = 'bank_name'
      AND data_type = 'text'
  ) THEN
    RAISE EXCEPTION 'EMPLOYEE_BANK_NAME_VERIFY_COLUMN_MISSING';
  END IF;

  IF to_regprocedure('public.create_store_employee(uuid,text,text,text,text,text,text)') IS NULL
     OR to_regprocedure('public.update_store_employee(uuid,uuid,text,text,text,text,text,text)') IS NULL THEN
    RAISE EXCEPTION 'EMPLOYEE_BANK_NAME_VERIFY_RPCS_MISSING';
  END IF;

  SELECT pg_get_functiondef('public.store_employee_profile_outbox_trigger()'::regprocedure)
  INTO v_definition;
  IF v_definition NOT LIKE '%NEW.bank_name IS DISTINCT FROM OLD.bank_name%' THEN
    RAISE EXCEPTION 'EMPLOYEE_BANK_NAME_VERIFY_VERSION_TRIGGER_INCOMPLETE';
  END IF;

  SELECT pg_get_function_result(
    'public.office_list_employee_payment_profiles(bigint,integer)'::regprocedure
  ) INTO v_result;
  IF v_result NOT LIKE '%bank_name text%' THEN
    RAISE EXCEPTION 'EMPLOYEE_BANK_NAME_VERIFY_OFFICE_SYNC_INCOMPLETE';
  END IF;

  IF NOT has_function_privilege(
    'authenticated',
    'public.create_store_employee(uuid,text,text,text,text,text,text)',
    'EXECUTE'
  ) OR NOT has_function_privilege(
    'authenticated',
    'public.update_store_employee(uuid,uuid,text,text,text,text,text,text)',
    'EXECUTE'
  ) OR NOT has_function_privilege(
    'service_role',
    'public.office_list_employee_payment_profiles(bigint,integer)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'EMPLOYEE_BANK_NAME_VERIFY_GRANTS_INCOMPLETE';
  END IF;
END;
$verify$;
