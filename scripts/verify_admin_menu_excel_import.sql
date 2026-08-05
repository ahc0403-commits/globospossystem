DO $verify$
DECLARE
  v_definition text;
  v_security_definer boolean;
BEGIN
  IF to_regprocedure('public.admin_import_menu_items(uuid,jsonb)') IS NULL THEN
    RAISE EXCEPTION 'MENU_EXCEL_IMPORT_VERIFY_RPC_MISSING';
  END IF;

  SELECT pg_get_functiondef(p.oid), p.prosecdef
  INTO v_definition, v_security_definer
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.oid = 'public.admin_import_menu_items(uuid,jsonb)'::regprocedure;

  IF NOT v_security_definer
     OR v_definition NOT LIKE '%require_admin_actor_for_restaurant(p_store_id)%'
     OR v_definition NOT LIKE '%MENU_IMPORT_TOO_MANY_ROWS%'
     OR v_definition NOT LIKE '%jsonb_array_length(p_rows) > 500%' THEN
    RAISE EXCEPTION 'MENU_EXCEL_IMPORT_VERIFY_AUTHORIZATION_OR_LIMIT_MISSING';
  END IF;

  IF NOT has_function_privilege(
    'authenticated',
    'public.admin_import_menu_items(uuid,jsonb)',
    'EXECUTE'
  ) OR has_function_privilege(
    'anon',
    'public.admin_import_menu_items(uuid,jsonb)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'MENU_EXCEL_IMPORT_VERIFY_GRANTS_INCORRECT';
  END IF;
END;
$verify$;
