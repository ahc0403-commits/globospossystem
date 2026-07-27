\set ON_ERROR_STOP on

DO $preflight$
BEGIN
  IF to_regclass('public.inventory_suppliers') IS NULL
     OR to_regclass('public.inventory_products') IS NULL
     OR to_regclass('public.inventory_items') IS NULL
     OR to_regclass('public.menu_recipes') IS NULL
     OR to_regclass('public.menu_items') IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_INGREDIENT_PREFLIGHT_TABLE_MISSING';
  END IF;

  IF to_regprocedure(
       'public.can_access_inventory_purchase_store(uuid)'
     ) IS NULL
     OR to_regprocedure(
       'public.upsert_inventory_product(uuid,uuid,text,text,text,text,text,numeric,text,text,integer,boolean)'
     ) IS NULL
     OR to_regprocedure(
       'public.get_inventory_recipe_catalog(uuid,uuid)'
     ) IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_INGREDIENT_PREFLIGHT_FUNCTION_MISSING';
  END IF;
END
$preflight$;

SELECT 'inventory ingredient Excel and supplier banking preflight passed'
  AS result;
