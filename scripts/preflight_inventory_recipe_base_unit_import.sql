\set ON_ERROR_STOP on

DO $preflight$
BEGIN
  IF to_regclass('public.inventory_items') IS NULL
     OR to_regclass('public.inventory_products') IS NULL
     OR to_regclass('public.menu_recipes') IS NULL
     OR to_regclass('public.menu_items') IS NULL
     OR to_regclass('public.menu_categories') IS NULL
     OR to_regclass('public.audit_logs') IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_BASE_UNIT_TABLE_MISSING';
  END IF;

  IF to_regprocedure(
       'public.can_access_inventory_purchase_store(uuid)'
     ) IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_BASE_UNIT_ACCESS_FUNCTION_MISSING';
  END IF;

  IF EXISTS (
    SELECT product.inventory_item_id
    FROM public.inventory_products product
    WHERE product.inventory_item_id IS NOT NULL
    GROUP BY product.inventory_item_id
    HAVING count(DISTINCT product.base_unit) > 1
  ) THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_BASE_UNIT_CONFLICT';
  END IF;
END
$preflight$;

SELECT 'inventory recipe base-unit import preflight passed' AS result;
