DO $verify$
DECLARE
  v_bulk regprocedure := to_regprocedure(
    'public.bulk_upsert_inventory_recipe_lines(uuid,jsonb)'
  );
  v_upsert regprocedure := to_regprocedure(
    'public.upsert_inventory_recipe_line(uuid,uuid,uuid,numeric)'
  );
  v_bulk_definition text;
  v_upsert_definition text;
BEGIN
  IF v_bulk IS NULL OR v_upsert IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_EXCEL_VERIFY_RPC_MISSING';
  END IF;

  SELECT pg_get_functiondef(v_bulk) INTO v_bulk_definition;
  SELECT pg_get_functiondef(v_upsert) INTO v_upsert_definition;

  IF position(
    'can_access_inventory_purchase_store(p_store_id)'
    IN v_bulk_definition
  ) = 0
     OR position('jsonb_array_length(p_lines)' IN v_bulk_definition) = 0
     OR position(
       'ON CONFLICT (menu_item_id, ingredient_id)'
       IN v_bulk_definition
     ) = 0
     OR position('restaurant_id = p_store_id' IN v_bulk_definition) = 0 THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_EXCEL_VERIFY_BULK_CONTRACT_INCOMPLETE';
  END IF;

  IF position(
    'bulk_upsert_inventory_recipe_lines'
    IN v_upsert_definition
  ) = 0 THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_EXCEL_VERIFY_MANUAL_ACCESS_NOT_ALIGNED';
  END IF;

  IF NOT has_function_privilege('authenticated', v_bulk, 'EXECUTE')
     OR NOT has_function_privilege('service_role', v_bulk, 'EXECUTE')
     OR has_function_privilege('anon', v_bulk, 'EXECUTE')
     OR NOT has_function_privilege('authenticated', v_upsert, 'EXECUTE')
     OR has_function_privilege('anon', v_upsert, 'EXECUTE') THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_EXCEL_VERIFY_GRANTS_INCOMPLETE';
  END IF;
END;
$verify$;

SELECT 'inventory recipe Excel import verification passed' AS result;
