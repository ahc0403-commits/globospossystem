DO $$
DECLARE
  v_function regprocedure :=
    to_regprocedure('public.set_menu_item_availability(uuid,boolean)');
  v_definition text;
  v_config text[];
  v_security_definer boolean;
BEGIN
  IF v_function IS NULL THEN
    RAISE EXCEPTION
      'Verification failed: set_menu_item_availability(uuid,boolean) is missing';
  END IF;

  SELECT
    pg_get_functiondef(proc.oid),
    proc.proconfig,
    proc.prosecdef
  INTO v_definition, v_config, v_security_definer
  FROM pg_proc proc
  WHERE proc.oid = v_function;

  IF NOT v_security_definer
     OR NOT (
       'search_path=public, auth, pg_catalog' = ANY(
         COALESCE(v_config, ARRAY[]::text[])
       )
     ) THEN
    RAISE EXCEPTION
      'Verification failed: sold-out RPC security contract is unsafe';
  END IF;

  IF position('''cashier''' IN v_definition) = 0
     OR position('''admin''' IN v_definition) = 0
     OR position('''store_admin''' IN v_definition) = 0
     OR position('''brand_admin''' IN v_definition) = 0
     OR position('''super_admin''' IN v_definition) = 0
     OR position('user_accessible_stores(auth.uid())' IN v_definition) = 0
     OR position('SET is_available = p_is_available' IN v_definition) = 0
     OR position('''set_menu_item_availability''' IN v_definition) = 0 THEN
    RAISE EXCEPTION
      'Verification failed: sold-out role, store scope, mutation, or audit contract is incomplete';
  END IF;

  IF NOT has_function_privilege(
    'authenticated',
    v_function,
    'EXECUTE'
  ) OR NOT has_function_privilege(
    'service_role',
    v_function,
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION
      'Verification failed: required roles cannot execute sold-out RPC';
  END IF;

  IF has_function_privilege('anon', v_function, 'EXECUTE')
     OR EXISTS (
       SELECT 1
       FROM pg_proc proc
       CROSS JOIN LATERAL aclexplode(
         COALESCE(proc.proacl, acldefault('f', proc.proowner))
       ) privilege
       WHERE proc.oid = v_function
         AND privilege.grantee = 0
         AND privilege.privilege_type = 'EXECUTE'
     ) THEN
    RAISE EXCEPTION
      'Verification failed: anon or PUBLIC can execute sold-out RPC';
  END IF;
END
$$;
