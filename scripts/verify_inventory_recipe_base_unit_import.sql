\set ON_ERROR_STOP on

DO $verify$
DECLARE
  v_bulk_function regprocedure := to_regprocedure(
    'public.bulk_upsert_inventory_recipe_lines(uuid,jsonb)'
  );
  v_menu_function regprocedure := to_regprocedure(
    'public.create_inventory_menu_with_recipe(uuid,uuid,text,numeric,text,jsonb)'
  );
  v_bulk_definition text;
  v_menu_definition text;
  v_bulk_config text[];
  v_menu_config text[];
BEGIN
  IF v_bulk_function IS NULL OR v_menu_function IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_BASE_UNIT_FUNCTION_MISSING';
  END IF;

  SELECT pg_get_functiondef(v_bulk_function), proconfig
  INTO v_bulk_definition, v_bulk_config
  FROM pg_proc
  WHERE oid = v_bulk_function;

  SELECT pg_get_functiondef(v_menu_function), proconfig
  INTO v_menu_definition, v_menu_config
  FROM pg_proc
  WHERE oid = v_menu_function;

  IF v_bulk_definition NOT LIKE '%quantity_base%'
     OR v_bulk_definition NOT LIKE '%INVENTORY_RECIPE_INGREDIENT_UNIT_MISMATCH%'
     OR v_bulk_definition NOT LIKE '%v_ingredient_unit NOT IN (''g'', ''ml'', ''ea'')%'
     OR v_bulk_definition LIKE '%unit <> ''g''%'
     OR v_menu_definition NOT LIKE '%base_unit%IN (''g'', ''ml'', ''ea'')%'
     OR NOT ('search_path=public, auth, pg_catalog' = ANY(v_bulk_config))
     OR NOT ('search_path=public, auth, pg_catalog' = ANY(v_menu_config))
     OR has_function_privilege('anon', v_bulk_function, 'EXECUTE')
     OR has_function_privilege('anon', v_menu_function, 'EXECUTE')
     OR NOT has_function_privilege('authenticated', v_bulk_function, 'EXECUTE')
     OR NOT has_function_privilege('authenticated', v_menu_function, 'EXECUTE') THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_BASE_UNIT_FUNCTION_INVALID';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.inventory_items ingredient
    JOIN public.inventory_products product
      ON product.inventory_item_id = ingredient.id
     AND product.restaurant_id = ingredient.restaurant_id
    WHERE product.base_unit IN ('g', 'ml', 'ea')
      AND ingredient.unit IS DISTINCT FROM product.base_unit
  ) THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_BASE_UNIT_SYNC_FAILED';
  END IF;

  IF col_description(
       'public.menu_recipes'::regclass,
       (
         SELECT attribute.attnum
         FROM pg_attribute attribute
         WHERE attribute.attrelid = 'public.menu_recipes'::regclass
           AND attribute.attname = 'quantity_g'
           AND NOT attribute.attisdropped
       )
     ) NOT LIKE '%canonical base unit%' THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_BASE_UNIT_COMMENT_MISSING';
  END IF;
END
$verify$;

SELECT 'inventory recipe base-unit import verification passed' AS result;
