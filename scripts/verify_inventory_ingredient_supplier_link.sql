\set ON_ERROR_STOP on

DO $verify$
DECLARE
  v_function regprocedure := to_regprocedure(
    'public.upsert_inventory_product_with_supplier(uuid,uuid,uuid,text,text,text,text,text,numeric,text,text,integer,boolean,text)'
  );
  v_definition text;
  v_config text[];
BEGIN
  IF v_function IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_INGREDIENT_SUPPLIER_LINK_FUNCTION_MISSING';
  END IF;

  SELECT pg_get_functiondef(v_function), proconfig
  INTO v_definition, v_config
  FROM pg_proc
  WHERE oid = v_function;

  IF v_definition NOT LIKE '%auth.uid() IS NULL%'
     OR v_definition NOT LIKE '%can_access_inventory_purchase_store%'
     OR v_definition NOT LIKE '%upsert_inventory_product(%'
     OR v_definition NOT LIKE '%upsert_inventory_supplier_item(%'
     OR v_definition NOT LIKE '%p_is_preferred := TRUE%'
     OR NOT ('search_path=pg_catalog, public, auth' = ANY(v_config))
     OR has_function_privilege('anon', v_function, 'EXECUTE')
     OR NOT has_function_privilege(
       'authenticated',
       v_function,
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'INVENTORY_INGREDIENT_SUPPLIER_LINK_FUNCTION_INVALID';
  END IF;
END
$verify$;

SELECT 'inventory ingredient supplier link verification passed' AS result;
