\set ON_ERROR_STOP on

DO $verify$
DECLARE
  v_supplier_function regprocedure := to_regprocedure(
    'public.upsert_inventory_supplier(uuid,uuid,text,text,text,text,text,text,text,text,date,date,text,text,text,text)'
  );
  v_recipe_function regprocedure := to_regprocedure(
    'public.get_inventory_recipe_catalog(uuid,uuid)'
  );
  v_import_function regprocedure := to_regprocedure(
    'public.bulk_upsert_inventory_ingredients(uuid,jsonb)'
  );
  v_definition text;
  v_config text[];
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'inventory_suppliers'
      AND column_name = 'bank_account_number'
      AND data_type = 'text'
  ) OR NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'inventory_suppliers'
      AND column_name = 'bank_name'
      AND data_type = 'text'
  ) OR NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'inventory_suppliers'
      AND column_name = 'bank_account_holder'
      AND data_type = 'text'
  ) THEN
    RAISE EXCEPTION 'SUPPLIER_BANKING_COLUMNS_MISSING';
  END IF;

  IF v_supplier_function IS NULL
     OR v_recipe_function IS NULL
     OR v_import_function IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_INGREDIENT_FUNCTION_MISSING';
  END IF;

  IF to_regprocedure(
       'public.upsert_inventory_supplier(uuid,uuid,text,text,text,text,text,text,text,text,date,date,text,text)'
     ) IS NOT NULL
     OR to_regprocedure(
       'public.upsert_inventory_supplier(uuid,uuid,text,text,text,text,text,text,text,text,date,date,text)'
     ) IS NOT NULL THEN
    RAISE EXCEPTION 'SUPPLIER_BANKING_LEGACY_OVERLOAD_PRESENT';
  END IF;

  SELECT pg_get_functiondef(v_supplier_function), proconfig
  INTO v_definition, v_config
  FROM pg_proc
  WHERE oid = v_supplier_function;
  IF v_definition NOT LIKE '%bank_name%'
     OR v_definition NOT LIKE '%bank_account_holder%'
     OR NOT ('search_path=public, auth, pg_catalog' = ANY(v_config))
     OR has_function_privilege('anon', v_supplier_function, 'EXECUTE')
     OR NOT has_function_privilege(
       'authenticated',
       v_supplier_function,
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'SUPPLIER_BANKING_FUNCTION_INVALID';
  END IF;

  SELECT pg_get_functiondef(v_recipe_function), proconfig
  INTO v_definition, v_config
  FROM pg_proc
  WHERE oid = v_recipe_function;
  IF v_definition NOT LIKE '%can_access_inventory_purchase_store%'
     OR NOT ('search_path=public, auth, pg_catalog' = ANY(v_config))
     OR has_function_privilege('anon', v_recipe_function, 'EXECUTE')
     OR NOT has_function_privilege(
       'authenticated',
       v_recipe_function,
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_ACCESS_FUNCTION_INVALID';
  END IF;

  SELECT pg_get_functiondef(v_import_function), proconfig
  INTO v_definition, v_config
  FROM pg_proc
  WHERE oid = v_import_function;
  IF v_definition NOT LIKE '%Validate every row before performing any mutation%'
     OR v_definition NOT LIKE '%upsert_inventory_product%'
     OR v_definition NOT LIKE '%inventory_ingredient_excel_imported%'
     OR NOT ('search_path=public, auth, pg_catalog' = ANY(v_config))
     OR has_function_privilege('anon', v_import_function, 'EXECUTE')
     OR NOT has_function_privilege(
       'authenticated',
       v_import_function,
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'INVENTORY_INGREDIENT_IMPORT_FUNCTION_INVALID';
  END IF;
END
$verify$;

SELECT 'inventory ingredient Excel and supplier banking verification passed'
  AS result;
