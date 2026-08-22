-- Recipe quantities follow each ingredient's canonical base unit (g, ml, ea).
-- The historical quantity_g column and RPC parameter remain for compatibility.

UPDATE public.inventory_items ingredient
SET unit = product.base_unit,
    updated_at = now()
FROM public.inventory_products product
WHERE product.inventory_item_id = ingredient.id
  AND product.restaurant_id = ingredient.restaurant_id
  AND product.base_unit IN ('g', 'ml', 'ea')
  AND ingredient.unit IS DISTINCT FROM product.base_unit;

COMMENT ON COLUMN public.menu_recipes.quantity_g IS
  'Quantity consumed per menu serving in the ingredient canonical base unit (g, ml, or ea). Legacy column name retained for API compatibility.';

CREATE OR REPLACE FUNCTION public.bulk_upsert_inventory_recipe_lines(
  p_store_id UUID,
  p_lines JSONB
) RETURNS JSONB AS $$
DECLARE
  v_line JSONB;
  v_menu_item_id UUID;
  v_ingredient_id UUID;
  v_quantity_base NUMERIC(10,3);
  v_source_row INTEGER;
  v_payload_unit TEXT;
  v_ingredient_unit TEXT;
  v_count INTEGER;
  v_seen TEXT[] := ARRAY[]::TEXT[];
  v_key TEXT;
BEGIN
  IF NOT public.can_access_inventory_purchase_store(p_store_id) THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_WRITE_FORBIDDEN';
  END IF;

  IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_IMPORT_LINES_INVALID';
  END IF;

  v_count := jsonb_array_length(p_lines);
  IF v_count < 1 OR v_count > 1000 THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_IMPORT_SIZE_INVALID';
  END IF;

  -- Validate the complete workbook before changing any recipe row.
  FOR v_line IN SELECT value FROM jsonb_array_elements(p_lines)
  LOOP
    BEGIN
      v_source_row := NULLIF(v_line->>'source_row', '')::INTEGER;
      v_menu_item_id := NULLIF(v_line->>'menu_item_id', '')::UUID;
      v_ingredient_id := NULLIF(v_line->>'ingredient_id', '')::UUID;
      v_quantity_base := NULLIF(
        COALESCE(v_line->>'quantity_base', v_line->>'quantity_g'),
        ''
      )::NUMERIC(10,3);
      v_payload_unit := lower(
        NULLIF(BTRIM(COALESCE(v_line->>'ingredient_unit', '')), '')
      );
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'INVENTORY_RECIPE_IMPORT_ROW_INVALID:%',
        COALESCE(v_line->>'source_row', '?');
    END;

    IF v_menu_item_id IS NULL OR NOT EXISTS (
      SELECT 1
      FROM public.menu_items menu
      WHERE menu.id = v_menu_item_id
        AND menu.restaurant_id = p_store_id
    ) THEN
      RAISE EXCEPTION 'INVENTORY_RECIPE_MENU_ITEM_NOT_FOUND:%',
        COALESCE(v_source_row::TEXT, '?');
    END IF;

    SELECT product.base_unit
    INTO v_ingredient_unit
    FROM public.inventory_products product
    JOIN public.inventory_items ingredient
      ON ingredient.id = product.inventory_item_id
     AND ingredient.restaurant_id = product.restaurant_id
    WHERE product.inventory_item_id = v_ingredient_id
      AND product.restaurant_id = p_store_id
      AND product.is_active = TRUE
    ORDER BY product.updated_at DESC, product.id
    LIMIT 1;

    IF v_ingredient_id IS NULL OR v_ingredient_unit IS NULL THEN
      RAISE EXCEPTION 'INVENTORY_RECIPE_INGREDIENT_NOT_FOUND:%',
        COALESCE(v_source_row::TEXT, '?');
    END IF;

    IF v_ingredient_unit NOT IN ('g', 'ml', 'ea') THEN
      RAISE EXCEPTION 'INVENTORY_RECIPE_INGREDIENT_UNIT_UNSUPPORTED:%',
        COALESCE(v_source_row::TEXT, '?');
    END IF;

    IF v_payload_unit IS NOT NULL AND v_payload_unit <> v_ingredient_unit THEN
      RAISE EXCEPTION 'INVENTORY_RECIPE_INGREDIENT_UNIT_MISMATCH:%',
        COALESCE(v_source_row::TEXT, '?');
    END IF;

    IF v_quantity_base IS NULL OR v_quantity_base <= 0 THEN
      RAISE EXCEPTION 'INVENTORY_RECIPE_QUANTITY_INVALID:%',
        COALESCE(v_source_row::TEXT, '?');
    END IF;

    v_key := v_menu_item_id::TEXT || ':' || v_ingredient_id::TEXT;
    IF v_key = ANY(v_seen) THEN
      RAISE EXCEPTION 'INVENTORY_RECIPE_IMPORT_DUPLICATE:%',
        COALESCE(v_source_row::TEXT, '?');
    END IF;
    v_seen := array_append(v_seen, v_key);
  END LOOP;

  FOR v_line IN SELECT value FROM jsonb_array_elements(p_lines)
  LOOP
    v_menu_item_id := (v_line->>'menu_item_id')::UUID;
    v_ingredient_id := (v_line->>'ingredient_id')::UUID;
    v_quantity_base := COALESCE(
      NULLIF(v_line->>'quantity_base', ''),
      v_line->>'quantity_g'
    )::NUMERIC(10,3);

    INSERT INTO public.menu_recipes (
      restaurant_id,
      menu_item_id,
      ingredient_id,
      quantity_g,
      updated_at
    ) VALUES (
      p_store_id,
      v_menu_item_id,
      v_ingredient_id,
      v_quantity_base,
      now()
    )
    ON CONFLICT (menu_item_id, ingredient_id)
    DO UPDATE SET
      quantity_g = EXCLUDED.quantity_g,
      updated_at = now();
  END LOOP;

  INSERT INTO public.audit_logs (
    actor_id,
    action,
    entity_type,
    entity_id,
    details
  ) VALUES (
    auth.uid(),
    'inventory_recipe_excel_imported',
    'menu_recipes',
    p_store_id,
    jsonb_build_object(
      'store_id', p_store_id,
      'line_count', v_count,
      'menu_count', (
        SELECT count(DISTINCT value->>'menu_item_id')
        FROM jsonb_array_elements(p_lines)
      ),
      'quantity_contract', 'ingredient_base_unit'
    )
  );

  RETURN jsonb_build_object(
    'store_id', p_store_id,
    'line_count', v_count,
    'quantity_contract', 'ingredient_base_unit'
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth, pg_catalog;

REVOKE ALL ON FUNCTION public.bulk_upsert_inventory_recipe_lines(UUID, JSONB)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.bulk_upsert_inventory_recipe_lines(UUID, JSONB)
  TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.create_inventory_menu_with_recipe(
  p_store_id UUID,
  p_category_id UUID DEFAULT NULL,
  p_name TEXT DEFAULT NULL,
  p_price NUMERIC DEFAULT 0,
  p_description TEXT DEFAULT NULL,
  p_recipe_lines JSONB DEFAULT '[]'::JSONB
) RETURNS public.menu_items AS $$
DECLARE
  v_menu public.menu_items%ROWTYPE;
  v_line JSONB;
  v_ingredient_id UUID;
  v_quantity_base NUMERIC;
BEGIN
  IF NOT public.can_access_inventory_purchase_store(p_store_id) THEN
    RAISE EXCEPTION 'INVENTORY_MENU_CREATE_FORBIDDEN';
  END IF;

  IF NULLIF(BTRIM(COALESCE(p_name, '')), '') IS NULL THEN
    RAISE EXCEPTION 'MENU_ITEM_NAME_REQUIRED';
  END IF;

  IF COALESCE(p_price, 0) < 0 THEN
    RAISE EXCEPTION 'MENU_ITEM_PRICE_INVALID';
  END IF;

  IF jsonb_typeof(COALESCE(p_recipe_lines, '[]'::JSONB)) <> 'array'
     OR jsonb_array_length(COALESCE(p_recipe_lines, '[]'::JSONB)) = 0 THEN
    RAISE EXCEPTION 'MENU_RECIPE_LINES_REQUIRED';
  END IF;

  IF p_category_id IS NOT NULL AND NOT EXISTS (
    SELECT 1
    FROM public.menu_categories category
    WHERE category.id = p_category_id
      AND category.restaurant_id = p_store_id
  ) THEN
    RAISE EXCEPTION 'MENU_CATEGORY_NOT_FOUND';
  END IF;

  INSERT INTO public.menu_items (
    restaurant_id,
    category_id,
    name,
    description,
    price,
    is_available,
    is_visible_public,
    sort_order,
    created_at,
    updated_at
  ) VALUES (
    p_store_id,
    p_category_id,
    BTRIM(p_name),
    NULLIF(BTRIM(COALESCE(p_description, '')), ''),
    COALESCE(p_price, 0),
    TRUE,
    FALSE,
    0,
    now(),
    now()
  )
  RETURNING * INTO v_menu;

  FOR v_line IN SELECT value FROM jsonb_array_elements(p_recipe_lines)
  LOOP
    v_ingredient_id := NULLIF(v_line->>'ingredient_id', '')::UUID;
    v_quantity_base := COALESCE(
      NULLIF(v_line->>'quantity_base', ''),
      NULLIF(v_line->>'quantity_g', '')
    )::NUMERIC;

    IF v_ingredient_id IS NULL OR COALESCE(v_quantity_base, 0) <= 0 THEN
      RAISE EXCEPTION 'MENU_RECIPE_LINE_INVALID';
    END IF;

    IF NOT EXISTS (
      SELECT 1
      FROM public.inventory_products product
      WHERE product.inventory_item_id = v_ingredient_id
        AND product.restaurant_id = p_store_id
        AND product.is_active = TRUE
        AND product.base_unit IN ('g', 'ml', 'ea')
    ) THEN
      RAISE EXCEPTION 'MENU_RECIPE_PRODUCT_NOT_FOUND';
    END IF;

    INSERT INTO public.menu_recipes (
      restaurant_id,
      menu_item_id,
      ingredient_id,
      quantity_g,
      updated_at
    ) VALUES (
      p_store_id,
      v_menu.id,
      v_ingredient_id,
      v_quantity_base,
      now()
    );
  END LOOP;

  RETURN v_menu;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth, pg_catalog;

REVOKE ALL ON FUNCTION public.create_inventory_menu_with_recipe(
  UUID, UUID, TEXT, NUMERIC, TEXT, JSONB
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_inventory_menu_with_recipe(
  UUID, UUID, TEXT, NUMERIC, TEXT, JSONB
) TO authenticated, service_role;
