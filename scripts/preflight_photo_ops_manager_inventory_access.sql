DO $$
BEGIN
  IF to_regprocedure('public.get_inventory_ingredient_catalog(uuid)') IS NULL THEN
    RAISE EXCEPTION 'PHOTO_OPS_INVENTORY_PREFLIGHT_FUNCTION_MISSING';
  END IF;
  IF to_regprocedure('public.user_accessible_stores(uuid)') IS NULL THEN
    RAISE EXCEPTION 'PHOTO_OPS_INVENTORY_PREFLIGHT_SCOPE_HELPER_MISSING';
  END IF;
  IF to_regclass('public.inventory_items') IS NULL
     OR to_regclass('public.users') IS NULL THEN
    RAISE EXCEPTION 'PHOTO_OPS_INVENTORY_PREFLIGHT_TABLE_MISSING';
  END IF;
END;
$$;

SELECT 'photo ops manager inventory access preflight passed' AS result;
