DO $preflight$
BEGIN
  IF to_regclass('public.store_employees') IS NULL THEN
    RAISE EXCEPTION 'EMPLOYEE_BANK_NAME_PREFLIGHT_STORE_EMPLOYEES_MISSING';
  END IF;
  IF to_regprocedure('public.create_store_employee(uuid,text,text,text,text,text)') IS NULL THEN
    RAISE EXCEPTION 'EMPLOYEE_BANK_NAME_PREFLIGHT_CREATE_RPC_MISSING';
  END IF;
  IF to_regprocedure('public.update_store_employee(uuid,uuid,text,text,text,text,text)') IS NULL THEN
    RAISE EXCEPTION 'EMPLOYEE_BANK_NAME_PREFLIGHT_UPDATE_RPC_MISSING';
  END IF;
  IF to_regprocedure('public.office_list_employee_payment_profiles(bigint,integer)') IS NULL THEN
    RAISE EXCEPTION 'EMPLOYEE_BANK_NAME_PREFLIGHT_OFFICE_SYNC_MISSING';
  END IF;
  IF to_regprocedure('public.store_employee_profile_outbox_trigger()') IS NULL THEN
    RAISE EXCEPTION 'EMPLOYEE_BANK_NAME_PREFLIGHT_VERSION_TRIGGER_MISSING';
  END IF;
END;
$preflight$;
