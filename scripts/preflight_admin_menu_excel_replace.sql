DO $$
BEGIN
  IF to_regprocedure('public.admin_import_menu_items(uuid,jsonb)') IS NULL THEN
    RAISE EXCEPTION
      'Preflight failed: public.admin_import_menu_items(uuid,jsonb) is missing';
  END IF;

  IF to_regprocedure('public.require_admin_actor_for_restaurant(uuid)') IS NULL THEN
    RAISE EXCEPTION
      'Preflight failed: admin authorization helper is missing';
  END IF;

  IF to_regprocedure(
    'public.admin_update_menu_workbook_i18n(uuid,jsonb,jsonb)'
  ) IS NULL THEN
    RAISE EXCEPTION
      'Preflight failed: multilingual menu workbook updater is missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'menu_items'
      AND column_name = 'image_url'
  ) OR NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'menu_items'
      AND column_name = 'image_storage_path'
  ) THEN
    RAISE EXCEPTION
      'Preflight failed: menu image metadata columns are missing';
  END IF;
END
$$;
