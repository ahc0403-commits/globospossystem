\set ON_ERROR_STOP on

DO $$
BEGIN
  IF to_regclass('public.inventory_items') IS NULL
     OR to_regclass('public.inventory_transactions') IS NULL
     OR to_regclass('public.inventory_physical_counts') IS NULL
     OR to_regclass('public.store_employees') IS NULL THEN
    RAISE EXCEPTION 'inventory daily stock prerequisites are missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname =
      'inventory_physical_counts_ingredient_id_count_date_key'
      AND conrelid = 'public.inventory_physical_counts'::regclass
  ) THEN
    RAISE EXCEPTION 'inventory physical-count daily uniqueness is missing';
  END IF;

  IF to_regprocedure(
    'public.user_accessible_stores(uuid)'
  ) IS NULL THEN
    RAISE EXCEPTION 'store-scope helper is missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'inventory_transactions'
      AND column_name = 'performed_by_employee_id'
  ) OR NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'inventory_physical_counts'
      AND column_name = 'performed_by_employee_id'
  ) THEN
    RAISE EXCEPTION 'employee inventory provenance columns are missing';
  END IF;

  IF to_regprocedure(
    'public.get_inventory_physical_count_sheet(uuid,date)'
  ) IS NULL OR to_regprocedure(
    'public.apply_inventory_physical_count_line(uuid,date,uuid,numeric,text)'
  ) IS NULL THEN
    RAISE EXCEPTION 'inventory RPC prerequisites are missing';
  END IF;
END;
$$;

SELECT 'inventory daily stock preflight passed' AS result;
