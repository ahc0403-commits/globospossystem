DO $preflight$
DECLARE
  v_upsert regprocedure := to_regprocedure(
    'public.upsert_inventory_recipe_line(uuid,uuid,uuid,numeric)'
  );
BEGIN
  IF to_regprocedure(
    'public.can_access_inventory_purchase_store(uuid)'
  ) IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_EXCEL_PREFLIGHT_ACCESS_HELPER_MISSING';
  END IF;

  IF v_upsert IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_EXCEL_PREFLIGHT_UPSERT_RPC_MISSING';
  END IF;

  IF to_regclass('public.menu_recipes') IS NULL
     OR to_regclass('public.menu_items') IS NULL
     OR to_regclass('public.inventory_items') IS NULL
     OR to_regclass('public.audit_logs') IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_EXCEL_PREFLIGHT_TABLE_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'menu_recipes'
      AND column_name = 'updated_at'
  ) THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_EXCEL_PREFLIGHT_UPDATED_AT_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint c
    WHERE c.conrelid = 'public.menu_recipes'::regclass
      AND c.contype = 'u'
      AND pg_get_constraintdef(c.oid)
          = 'UNIQUE (menu_item_id, ingredient_id)'
  ) THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_EXCEL_PREFLIGHT_UNIQUE_KEY_MISSING';
  END IF;
END;
$preflight$;

SELECT 'inventory recipe Excel import preflight passed' AS result;
