\set ON_ERROR_STOP on

BEGIN;
SET LOCAL request.jwt.claim.role = 'service_role';

DO $test$
DECLARE
  v_store_id uuid;
  v_supplier public.inventory_suppliers%ROWTYPE;
  v_excel_supplier_name text :=
    'Codex Excel-created supplier ' || gen_random_uuid()::text;
  v_result jsonb;
BEGIN
  SELECT id
  INTO v_store_id
  FROM public.restaurants
  ORDER BY created_at, id
  LIMIT 1;

  IF v_store_id IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_INGREDIENT_TEST_STORE_MISSING';
  END IF;

  SELECT *
  INTO v_supplier
  FROM public.upsert_inventory_supplier(
    p_store_id => v_store_id,
    p_supplier_name => 'Codex supplier banking verification',
    p_bank_account_number => '0123456789',
    p_bank_name => 'Vietcombank',
    p_bank_account_holder => 'CODEX VERIFY'
  );

  IF v_supplier.bank_account_number <> '0123456789'
     OR v_supplier.bank_name <> 'Vietcombank'
     OR v_supplier.bank_account_holder <> 'CODEX VERIFY' THEN
    RAISE EXCEPTION 'SUPPLIER_BANKING_ROUND_TRIP_FAILED';
  END IF;

  SELECT public.bulk_upsert_inventory_ingredients(
    v_store_id,
    jsonb_build_array(
      jsonb_build_object(
        'source_row', 2,
        'product_code', 'CODEX-INGREDIENT-EXCEL-VERIFY',
        'name', 'Codex ingredient verification',
        'category', 'Verification',
        'stock_unit', 'kg',
        'base_unit', 'g',
        'base_unit_factor', 1000,
        'storage_type', 'dry',
        'shelf_life_days', 7,
        'is_orderable', true,
        'supplier_name', v_excel_supplier_name,
        'unit_price', 125000
      ),
      jsonb_build_object(
        'source_row', 3,
        'product_code', 'CODEX-INGREDIENT-EXCEL-CACHED-COMPAT',
        'name', 'Codex cached client ingredient',
        'category', 'Verification',
        'stock_unit', 'kg',
        'base_unit', 'g',
        'base_unit_factor', 1000,
        'storage_type', 'dry',
        'shelf_life_days', 7,
        'is_orderable', true,
        'supplier_id', v_supplier.id,
        'unit_price', 99000
      )
    )
  )
  INTO v_result;

  IF (v_result->>'row_count')::integer <> 2
     OR (v_result->>'supplier_created_count')::integer <> 1
     OR NOT EXISTS (
       SELECT 1
       FROM public.inventory_products product
       JOIN public.inventory_items ingredient
         ON ingredient.id = product.inventory_item_id
        AND ingredient.restaurant_id = product.restaurant_id
       WHERE product.restaurant_id = v_store_id
         AND product.product_code = 'CODEX-INGREDIENT-EXCEL-VERIFY'
         AND product.name = 'Codex ingredient verification'
         AND ingredient.name = 'Codex ingredient verification'
         AND ingredient.unit = 'g'
         AND EXISTS (
           SELECT 1
           FROM public.inventory_supplier_items supplier_item
           JOIN public.inventory_suppliers supplier
             ON supplier.id = supplier_item.supplier_id
           WHERE supplier_item.product_id = product.id
             AND supplier.supplier_name = v_excel_supplier_name
             AND supplier_item.unit_price = 125000
             AND supplier_item.is_preferred = true
             AND supplier_item.is_active = true
         )
     ) THEN
    RAISE EXCEPTION 'INGREDIENT_EXCEL_ROUND_TRIP_FAILED';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.inventory_products product
    WHERE product.restaurant_id = v_store_id
      AND product.product_code = 'CODEX-INGREDIENT-EXCEL-CACHED-COMPAT'
      AND product.name = 'Codex cached client ingredient'
      AND EXISTS (
        SELECT 1
        FROM public.inventory_supplier_items supplier_item
        WHERE supplier_item.product_id = product.id
          AND supplier_item.supplier_id = v_supplier.id
          AND supplier_item.unit_price = 99000
          AND supplier_item.is_preferred = true
          AND supplier_item.is_active = true
      )
  ) THEN
    RAISE EXCEPTION 'INGREDIENT_EXCEL_CACHED_CLIENT_COMPAT_FAILED';
  END IF;

  PERFORM *
  FROM public.get_inventory_recipe_catalog(v_store_id, NULL);
END
$test$;

SELECT 'inventory ingredient Excel and supplier banking integration passed'
  AS result;

ROLLBACK;
