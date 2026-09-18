\set ON_ERROR_STOP on

DO $$
BEGIN
  IF to_regclass('public.menu_items') IS NULL
     OR to_regclass('public.menu_categories') IS NULL
     OR to_regclass('public.menu_combo_components') IS NULL
     OR to_regclass('public.audit_logs') IS NULL
     OR to_regprocedure('public.require_admin_actor_for_restaurant(uuid)') IS NULL
     OR to_regprocedure('public.admin_delete_menu_category(uuid)') IS NULL THEN
    RAISE EXCEPTION 'ADMIN_MENU_ARCHIVE_PREREQUISITES_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'menu_items'
      AND column_name = 'is_archived'
      AND data_type = 'boolean'
  ) THEN
    RAISE EXCEPTION 'ADMIN_MENU_ARCHIVE_COLUMN_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint constraint_row
    WHERE constraint_row.conrelid = 'public.menu_items'::regclass
      AND constraint_row.contype = 'f'
      AND pg_get_constraintdef(constraint_row.oid) LIKE
        '%category_id%REFERENCES menu_categories(id) ON DELETE SET NULL%'
  ) THEN
    RAISE EXCEPTION 'ADMIN_MENU_ARCHIVE_CATEGORY_FK_INVALID';
  END IF;
END;
$$;

SELECT 'ADMIN_MENU_ITEM_ARCHIVE_PREFLIGHT_OK' AS result;
