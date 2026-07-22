DO $verify$
DECLARE
  v_definition text;
  v_security_definer boolean;
BEGIN
  IF to_regprocedure('public.print_routing_actor_can_run(uuid)') IS NULL THEN
    RAISE EXCEPTION 'CASHIER_PRINT_AGENT_VERIFY_FUNCTION_MISSING';
  END IF;

  SELECT pg_get_functiondef(p.oid), p.prosecdef
  INTO v_definition, v_security_definer
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.oid = 'public.print_routing_actor_can_run(uuid)'::regprocedure;

  IF NOT v_security_definer THEN
    RAISE EXCEPTION 'CASHIER_PRINT_AGENT_VERIFY_SECURITY_DEFINER_MISSING';
  END IF;

  IF v_definition NOT LIKE '%cashier%'
     OR v_definition NOT LIKE '%user_accessible_stores(auth.uid())%' THEN
    RAISE EXCEPTION 'CASHIER_PRINT_AGENT_VERIFY_STORE_SCOPE_INCOMPLETE';
  END IF;

  IF has_function_privilege(
    'anon',
    'public.print_routing_actor_can_run(uuid)',
    'EXECUTE'
  ) OR has_function_privilege(
    'authenticated',
    'public.print_routing_actor_can_run(uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'CASHIER_PRINT_AGENT_VERIFY_DIRECT_EXECUTE_EXPOSED';
  END IF;
END;
$verify$;
