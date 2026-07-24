-- Atomic Excel recipe import and current store-access contract.

CREATE OR REPLACE FUNCTION public.bulk_upsert_inventory_recipe_lines(
  p_store_id UUID,
  p_lines JSONB
) RETURNS JSONB AS $$
DECLARE
  v_line JSONB;
  v_menu_item_id UUID;
  v_ingredient_id UUID;
  v_quantity_g NUMERIC(10,3);
  v_source_row INTEGER;
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

  -- Validate the complete workbook before changing any row.
  FOR v_line IN SELECT value FROM jsonb_array_elements(p_lines)
  LOOP
    BEGIN
      v_source_row := NULLIF(v_line->>'source_row', '')::INTEGER;
      v_menu_item_id := NULLIF(v_line->>'menu_item_id', '')::UUID;
      v_ingredient_id := NULLIF(v_line->>'ingredient_id', '')::UUID;
      v_quantity_g := NULLIF(v_line->>'quantity_g', '')::NUMERIC(10,3);
    EXCEPTION WHEN OTHERS THEN
      RAISE EXCEPTION 'INVENTORY_RECIPE_IMPORT_ROW_INVALID:%',
        COALESCE(v_line->>'source_row', '?');
    END;

    IF v_menu_item_id IS NULL OR NOT EXISTS (
      SELECT 1
      FROM public.menu_items mi
      WHERE mi.id = v_menu_item_id
        AND mi.restaurant_id = p_store_id
    ) THEN
      RAISE EXCEPTION 'INVENTORY_RECIPE_MENU_ITEM_NOT_FOUND:%',
        COALESCE(v_source_row::TEXT, '?');
    END IF;

    IF v_ingredient_id IS NULL OR NOT EXISTS (
      SELECT 1
      FROM public.inventory_items ii
      WHERE ii.id = v_ingredient_id
        AND ii.restaurant_id = p_store_id
    ) THEN
      RAISE EXCEPTION 'INVENTORY_RECIPE_INGREDIENT_NOT_FOUND:%',
        COALESCE(v_source_row::TEXT, '?');
    END IF;

    IF EXISTS (
      SELECT 1
      FROM public.inventory_items ii
      WHERE ii.id = v_ingredient_id
        AND ii.unit <> 'g'
    ) THEN
      RAISE EXCEPTION 'INVENTORY_RECIPE_INGREDIENT_UNIT_UNSUPPORTED:%',
        COALESCE(v_source_row::TEXT, '?');
    END IF;

    IF v_quantity_g IS NULL OR v_quantity_g <= 0 THEN
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
    v_quantity_g := (v_line->>'quantity_g')::NUMERIC(10,3);

    INSERT INTO public.menu_recipes (
      restaurant_id,
      menu_item_id,
      ingredient_id,
      quantity_g,
      updated_at
    )
    VALUES (
      p_store_id,
      v_menu_item_id,
      v_ingredient_id,
      v_quantity_g,
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
  )
  VALUES (
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
      )
    )
  );

  RETURN jsonb_build_object(
    'store_id', p_store_id,
    'line_count', v_count
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

REVOKE ALL ON FUNCTION public.bulk_upsert_inventory_recipe_lines(UUID, JSONB)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.bulk_upsert_inventory_recipe_lines(UUID, JSONB)
  TO authenticated, service_role;

-- Align manual recipe registration with the same accessible-store contract.
CREATE OR REPLACE FUNCTION public.upsert_inventory_recipe_line(
  p_store_id UUID,
  p_menu_item_id UUID,
  p_ingredient_id UUID,
  p_quantity_g DECIMAL(10,3)
) RETURNS TABLE (
  recipe_id UUID,
  restaurant_id UUID,
  menu_item_id UUID,
  menu_item_name TEXT,
  ingredient_id UUID,
  ingredient_name TEXT,
  ingredient_unit TEXT,
  quantity_g DECIMAL(10,3),
  last_updated TIMESTAMPTZ
) AS $$
BEGIN
  PERFORM public.bulk_upsert_inventory_recipe_lines(
    p_store_id,
    jsonb_build_array(
      jsonb_build_object(
        'source_row', 1,
        'menu_item_id', p_menu_item_id,
        'ingredient_id', p_ingredient_id,
        'quantity_g', p_quantity_g
      )
    )
  );

  RETURN QUERY
  SELECT
    mr.id,
    mr.restaurant_id,
    mr.menu_item_id,
    mi.name,
    mr.ingredient_id,
    ii.name,
    ii.unit,
    mr.quantity_g,
    mr.updated_at
  FROM public.menu_recipes mr
  JOIN public.menu_items mi ON mi.id = mr.menu_item_id
  JOIN public.inventory_items ii ON ii.id = mr.ingredient_id
  WHERE mr.restaurant_id = p_store_id
    AND mr.menu_item_id = p_menu_item_id
    AND mr.ingredient_id = p_ingredient_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

REVOKE ALL ON FUNCTION public.upsert_inventory_recipe_line(
  UUID, UUID, UUID, DECIMAL
) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.upsert_inventory_recipe_line(
  UUID, UUID, UUID, DECIMAL
) TO authenticated, service_role;
