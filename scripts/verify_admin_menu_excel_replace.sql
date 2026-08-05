DO $$
DECLARE
  v_definition TEXT;
BEGIN
  SELECT pg_get_functiondef('public.admin_import_menu_items(uuid,jsonb)'::regprocedure)
  INTO v_definition;

  IF position('admin_replace_menu_catalog' IN v_definition) = 0
     OR position('preserved_image_count' IN v_definition) = 0
     OR position('DELETE FROM public.menu_items' IN v_definition) = 0 THEN
    RAISE EXCEPTION
      'Verification failed: menu replacement function body is incomplete';
  END IF;

  IF NOT has_function_privilege(
    'authenticated',
    'public.admin_import_menu_items(uuid,jsonb)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION
      'Verification failed: authenticated role cannot execute menu replacement';
  END IF;

  IF has_function_privilege(
    'anon',
    'public.admin_import_menu_items(uuid,jsonb)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION
      'Verification failed: anon role can execute menu replacement';
  END IF;
END
$$;
