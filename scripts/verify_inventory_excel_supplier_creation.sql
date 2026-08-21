\set ON_ERROR_STOP on

DO $verify$
DECLARE
  v_import_function regprocedure := to_regprocedure(
    'public.bulk_upsert_inventory_ingredients(uuid,jsonb)'
  );
  v_definition text;
  v_config text[];
BEGIN
  IF v_import_function IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_EXCEL_SUPPLIER_CREATION_FUNCTION_MISSING';
  END IF;

  SELECT pg_get_functiondef(v_import_function), proconfig
  INTO v_definition, v_config
  FROM pg_proc
  WHERE oid = v_import_function;

  IF v_definition NOT LIKE '%v_row->>''supplier_name''%'
     OR v_definition NOT LIKE '%v_existing_supplier_name%'
     OR v_definition NOT LIKE '%Cached clients from the supplier-price release%'
     OR v_definition NOT LIKE '%INVENTORY_INGREDIENT_SUPPLIER_AMBIGUOUS%'
     OR v_definition NOT LIKE '%upsert_inventory_supplier(%'
     OR v_definition NOT LIKE '%pg_advisory_xact_lock%'
     OR v_definition NOT LIKE '%supplier_created_count%'
     OR v_definition NOT LIKE '%upsert_inventory_supplier_item%'
     OR v_definition NOT LIKE '%p_unit_price := v_unit_price%'
     OR NOT ('search_path=public, auth, pg_catalog' = ANY(v_config))
     OR has_function_privilege('anon', v_import_function, 'EXECUTE')
     OR NOT has_function_privilege(
       'authenticated',
       v_import_function,
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'INVENTORY_EXCEL_SUPPLIER_CREATION_FUNCTION_INVALID';
  END IF;
END
$verify$;

SELECT 'inventory Excel supplier creation verification passed' AS result;
