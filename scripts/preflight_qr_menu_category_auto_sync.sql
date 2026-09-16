DO $preflight$
BEGIN
  IF to_regclass('public.menu_categories') IS NULL
     OR to_regclass('public.menu_items') IS NULL
     OR to_regclass('public.table_qr_tokens') IS NULL
     OR to_regprocedure('public.qr_get_menu(text)') IS NULL
     OR to_regprocedure(
       'public.admin_create_menu_item_i18n_paperless(uuid,uuid,text,text,text,text,numeric,integer,boolean)'
     ) IS NULL THEN
    RAISE EXCEPTION 'QR_MENU_CATEGORY_AUTO_SYNC_DEPENDENCY_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'menu_items'
      AND column_name = 'is_visible_public'
      AND data_type = 'boolean'
  ) THEN
    RAISE EXCEPTION 'QR_MENU_PUBLIC_VISIBILITY_COLUMN_MISSING';
  END IF;
END;
$preflight$;

DO $preflight$
BEGIN
  IF has_function_privilege(
       'public',
       'public.qr_get_menu(text)',
       'EXECUTE'
     )
     OR NOT has_function_privilege(
       'anon',
       'public.qr_get_menu(text)',
       'EXECUTE'
     )
     OR NOT has_function_privilege(
       'authenticated',
       'public.qr_get_menu(text)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'QR_MENU_EXECUTE_PRIVILEGE_INVALID';
  END IF;
END;
$preflight$;
