DO $$
BEGIN
  IF to_regprocedure('public.user_accessible_stores(uuid)') IS NULL THEN
    RAISE EXCEPTION
      'Preflight failed: public.user_accessible_stores(uuid) is missing';
  END IF;

  IF to_regclass('public.menu_items') IS NULL
     OR to_regclass('public.users') IS NULL
     OR to_regclass('public.audit_logs') IS NULL THEN
    RAISE EXCEPTION
      'Preflight failed: sold-out authorization or audit tables are missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'menu_items'
      AND column_name = 'is_available'
      AND data_type = 'boolean'
  ) OR NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'menu_items'
      AND column_name = 'is_archived'
      AND data_type = 'boolean'
  ) THEN
    RAISE EXCEPTION
      'Preflight failed: menu availability columns are missing or incompatible';
  END IF;
END
$$;
