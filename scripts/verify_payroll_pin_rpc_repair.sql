DO $$
DECLARE
  v_set_definition text;
  v_clear_definition text;
BEGIN
  IF to_regprocedure('public.set_payroll_pin(uuid,text)') IS NULL
     OR to_regprocedure('public.clear_payroll_pin(uuid)') IS NULL THEN
    RAISE EXCEPTION 'PAYROLL_PIN_REPAIR_FUNCTION_MISSING';
  END IF;

  SELECT pg_get_functiondef(
    'public.set_payroll_pin(uuid,text)'::regprocedure
  ) INTO v_set_definition;
  SELECT pg_get_functiondef(
    'public.clear_payroll_pin(uuid)'::regprocedure
  ) INTO v_clear_definition;

  IF position(
       'require_admin_actor_for_restaurant' IN v_set_definition
     ) = 0
     OR position('PAYROLL_PIN_HASH_INVALID' IN v_set_definition) = 0
     OR position('set_payroll_pin' IN v_set_definition) = 0
     OR position(
       'require_admin_actor_for_restaurant' IN v_clear_definition
     ) = 0
     OR position('clear_payroll_pin' IN v_clear_definition) = 0 THEN
    RAISE EXCEPTION 'PAYROLL_PIN_REPAIR_DEFINITION_INVALID';
  END IF;

  IF pg_get_function_result(
       'public.set_payroll_pin(uuid,text)'::regprocedure
     ) <> 'boolean'
     OR pg_get_function_result(
       'public.clear_payroll_pin(uuid)'::regprocedure
     ) <> 'boolean' THEN
    RAISE EXCEPTION 'PAYROLL_PIN_REPAIR_RETURN_CONTRACT_INVALID';
  END IF;

  IF has_function_privilege(
       'anon',
       'public.set_payroll_pin(uuid,text)',
       'EXECUTE'
     )
     OR has_function_privilege(
       'anon',
       'public.clear_payroll_pin(uuid)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'PAYROLL_PIN_REPAIR_ANON_EXECUTE_NOT_REVOKED';
  END IF;

  IF NOT has_function_privilege(
       'authenticated',
       'public.set_payroll_pin(uuid,text)',
       'EXECUTE'
     )
     OR NOT has_function_privilege(
       'authenticated',
       'public.clear_payroll_pin(uuid)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'PAYROLL_PIN_REPAIR_AUTHENTICATED_EXECUTE_MISSING';
  END IF;
END;
$$;

SELECT 'payroll PIN RPC repair verification passed' AS result;
