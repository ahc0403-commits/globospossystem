\set ON_ERROR_STOP on

DO $preflight$
BEGIN
  IF to_regclass('public.inventory_products') IS NULL
     OR to_regclass('public.inventory_suppliers') IS NULL
     OR to_regclass('public.inventory_supplier_items') IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_INGREDIENT_SUPPLIER_TABLE_MISSING';
  END IF;

  IF to_regprocedure(
       'public.can_access_inventory_purchase_store(uuid)'
     ) IS NULL
     OR to_regprocedure(
       'public.upsert_inventory_product(uuid,uuid,text,text,text,text,text,numeric,text,text,integer,boolean)'
     ) IS NULL
     OR to_regprocedure(
       'public.upsert_inventory_supplier_item(uuid,uuid,uuid,uuid,text,text,numeric,numeric,numeric,numeric,integer,boolean)'
     ) IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_INGREDIENT_SUPPLIER_FUNCTION_MISSING';
  END IF;
END
$preflight$;

SELECT 'inventory ingredient supplier link preflight passed' AS result;
