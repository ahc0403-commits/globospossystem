-- ============================================================
-- Inventory New Menu Registration RPC
-- 2026-05-06
--
-- Creates a POS menu item and its recipe lines atomically from the
-- inventory purchase new-menu workflow.
-- ============================================================

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
  v_quantity_g NUMERIC;
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
    FROM public.menu_categories
    WHERE id = p_category_id
      AND restaurant_id = p_store_id
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

  FOR v_line IN SELECT * FROM jsonb_array_elements(p_recipe_lines)
  LOOP
    v_ingredient_id := NULLIF(v_line->>'ingredient_id', '')::UUID;
    v_quantity_g := COALESCE(NULLIF(v_line->>'quantity_g', '')::NUMERIC, 0);

    IF v_ingredient_id IS NULL OR v_quantity_g <= 0 THEN
      RAISE EXCEPTION 'MENU_RECIPE_LINE_INVALID';
    END IF;

    IF NOT EXISTS (
      SELECT 1
      FROM public.inventory_products ip
      WHERE ip.inventory_item_id = v_ingredient_id
        AND ip.restaurant_id = p_store_id
        AND ip.is_active = TRUE
        AND ip.base_unit = 'g'
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
      v_quantity_g,
      now()
    );
  END LOOP;

  RETURN v_menu;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

GRANT EXECUTE ON FUNCTION public.create_inventory_menu_with_recipe(UUID, UUID, TEXT, NUMERIC, TEXT, JSONB) TO authenticated;
