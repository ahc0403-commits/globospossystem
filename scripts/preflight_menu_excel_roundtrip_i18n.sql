DO $preflight$
BEGIN
  IF to_regclass('public.menu_categories') IS NULL
     OR to_regclass('public.menu_items') IS NULL
     OR to_regclass('public.audit_logs') IS NULL THEN
    RAISE EXCEPTION 'MENU_ROUNDTRIP_PREFLIGHT_BASE_TABLES_MISSING';
  END IF;

  IF to_regprocedure('public.require_admin_actor_for_restaurant(uuid)') IS NULL
     OR to_regprocedure('public.admin_update_menu_category_i18n(uuid,text,text,text)') IS NULL
     OR to_regprocedure('public.admin_update_menu_item_i18n(uuid,text,text,text,numeric)') IS NULL THEN
    RAISE EXCEPTION 'MENU_ROUNDTRIP_PREFLIGHT_DEPENDENCIES_MISSING';
  END IF;

  IF (
    SELECT count(*)
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name IN ('menu_categories', 'menu_items')
      AND column_name IN ('name_ko', 'name_vi', 'name_en')
      AND data_type = 'text'
  ) <> 6 THEN
    RAISE EXCEPTION 'MENU_ROUNDTRIP_PREFLIGHT_I18N_COLUMNS_MISSING';
  END IF;

  IF to_regprocedure(
    'public.admin_update_menu_workbook_i18n(uuid,jsonb,jsonb)'
  ) IS NOT NULL THEN
    RAISE EXCEPTION 'MENU_ROUNDTRIP_PREFLIGHT_PARTIAL_STATE_DETECTED';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.menu_categories
    WHERE NULLIF(btrim(name_ko), '') IS NULL
       OR NULLIF(btrim(name_vi), '') IS NULL
       OR NULLIF(btrim(name_en), '') IS NULL
  ) OR EXISTS (
    SELECT 1 FROM public.menu_items
    WHERE NULLIF(btrim(name_ko), '') IS NULL
       OR NULLIF(btrim(name_vi), '') IS NULL
       OR NULLIF(btrim(name_en), '') IS NULL
  ) THEN
    RAISE EXCEPTION 'MENU_ROUNDTRIP_PREFLIGHT_I18N_DATA_INCOMPLETE';
  END IF;
END;
$preflight$;
