DO $verify$
DECLARE
  v_definition text;
BEGIN
  IF to_regprocedure(
    'public.require_printer_configuration_actor(uuid)'
  ) IS NULL
     OR to_regprocedure(
       'public.admin_upsert_printer_destination_v2(uuid,uuid,text,text,text,boolean,text,integer,text,integer)'
     ) IS NULL
     OR to_regprocedure(
       'public.admin_delete_printer_destination(uuid,uuid)'
     ) IS NULL
     OR to_regprocedure(
       'public.admin_enqueue_printer_test_job(uuid,uuid)'
     ) IS NULL THEN
    RAISE EXCEPTION 'PRINT_CONFIGURATION_FUNCTIONS_MISSING';
  END IF;

  SELECT pg_get_functiondef(
    'public.require_printer_configuration_actor(uuid)'::regprocedure
  ) INTO v_definition;
  IF position('device_print_station' IN v_definition) = 0
     OR position('user_accessible_stores' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'PRINT_CONFIGURATION_STORE_SCOPE_MISSING';
  END IF;

  IF has_function_privilege(
       'anon',
       'public.admin_enqueue_printer_test_job(uuid,uuid)',
       'EXECUTE'
     )
     OR NOT has_function_privilege(
       'authenticated',
       'public.admin_enqueue_printer_test_job(uuid,uuid)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'PRINT_CONFIGURATION_GRANT_INVALID';
  END IF;
END;
$verify$;
