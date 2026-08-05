DO $$
DECLARE
  v_definition TEXT;
  v_roundtrip_definition TEXT;
BEGIN
  SELECT pg_get_functiondef('public.admin_import_menu_items(uuid,jsonb)'::regprocedure)
  INTO v_definition;

  IF position('admin_replace_menu_catalog' IN v_definition) = 0
     OR position('preserved_image_count' IN v_definition) = 0
     OR position('is_archived = true' IN v_definition) = 0 THEN
    RAISE EXCEPTION
      'Verification failed: menu replacement function body is incomplete';
  END IF;

  SELECT pg_get_functiondef(
    'public.admin_update_menu_workbook_i18n(uuid,jsonb,jsonb)'::regprocedure
  ) INTO v_roundtrip_definition;

  IF position('admin_update_menu_workbook_i18n_apply' IN v_roundtrip_definition) = 0
     OR position('is_archived = true' IN v_roundtrip_definition) = 0
     OR position('preserved_image_count' IN v_roundtrip_definition) = 0 THEN
    RAISE EXCEPTION
      'Verification failed: multilingual replacement wrapper is incomplete';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'menu_items'
      AND column_name = 'is_archived'
  ) THEN
    RAISE EXCEPTION
      'Verification failed: menu archive column is missing';
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
