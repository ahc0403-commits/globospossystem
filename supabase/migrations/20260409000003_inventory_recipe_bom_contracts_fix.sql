-- ============================================================
-- POS Inventory Recipe/BOM Mapping contract fix
-- 2026-04-09
-- Fixes runtime ambiguous-column references in upsert function.
-- ============================================================

CREATE OR REPLACE FUNCTION public.upsert_inventory_recipe_line(
  p_restaurant_id UUID,
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
DECLARE
  v_actor public.users%ROWTYPE;
  v_menu_item public.menu_items%ROWTYPE;
  v_ingredient public.inventory_items%ROWTYPE;
  v_existing public.menu_recipes%ROWTYPE;
  v_recipe public.menu_recipes%ROWTYPE;
  v_changed_fields TEXT[] := ARRAY[]::TEXT[];
  v_old_values JSONB := '{}'::JSONB;
  v_new_values JSONB := '{}'::JSONB;
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_WRITE_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_restaurant_id THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_WRITE_FORBIDDEN';
  END IF;

  IF p_menu_item_id IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_MENU_ITEM_REQUIRED';
  END IF;

  IF p_ingredient_id IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_INGREDIENT_REQUIRED';
  END IF;

  IF p_quantity_g IS NULL OR p_quantity_g <= 0 THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_QUANTITY_INVALID';
  END IF;

  SELECT mi.*
  INTO v_menu_item
  FROM public.menu_items mi
  WHERE mi.id = p_menu_item_id
    AND mi.restaurant_id = p_restaurant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_MENU_ITEM_NOT_FOUND';
  END IF;

  SELECT ii.*
  INTO v_ingredient
  FROM public.inventory_items ii
  WHERE ii.id = p_ingredient_id
    AND ii.restaurant_id = p_restaurant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_INGREDIENT_NOT_FOUND';
  END IF;

  IF v_ingredient.unit <> 'g' THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_INGREDIENT_UNIT_UNSUPPORTED';
  END IF;

  SELECT mr.*
  INTO v_existing
  FROM public.menu_recipes mr
  WHERE mr.restaurant_id = p_restaurant_id
    AND mr.menu_item_id = p_menu_item_id
    AND mr.ingredient_id = p_ingredient_id
  FOR UPDATE;

  IF FOUND THEN
    IF v_existing.quantity_g IS DISTINCT FROM p_quantity_g THEN
      v_changed_fields := ARRAY['quantity_g'];
      v_old_values := jsonb_build_object('quantity_g', v_existing.quantity_g);
      v_new_values := jsonb_build_object('quantity_g', p_quantity_g);

      UPDATE public.menu_recipes mr
      SET quantity_g = p_quantity_g,
          updated_at = now()
      WHERE mr.id = v_existing.id
      RETURNING mr.* INTO v_recipe;

      INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
      VALUES (
        auth.uid(),
        'inventory_recipe_upserted',
        'menu_recipes',
        v_recipe.id,
        jsonb_build_object(
          'operation', 'update',
          'restaurant_id', p_restaurant_id,
          'menu_item_id', p_menu_item_id,
          'ingredient_id', p_ingredient_id,
          'changed_fields', to_jsonb(v_changed_fields),
          'old_values', v_old_values,
          'new_values', v_new_values
        )
      );
    ELSE
      v_recipe := v_existing;
    END IF;
  ELSE
    INSERT INTO public.menu_recipes (
      restaurant_id,
      menu_item_id,
      ingredient_id,
      quantity_g,
      updated_at
    )
    VALUES (
      p_restaurant_id,
      p_menu_item_id,
      p_ingredient_id,
      p_quantity_g,
      now()
    )
    RETURNING * INTO v_recipe;

    INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
    VALUES (
      auth.uid(),
      'inventory_recipe_upserted',
      'menu_recipes',
      v_recipe.id,
      jsonb_build_object(
        'operation', 'create',
        'restaurant_id', p_restaurant_id,
        'menu_item_id', p_menu_item_id,
        'ingredient_id', p_ingredient_id,
        'new_values', jsonb_build_object(
          'quantity_g', v_recipe.quantity_g
        )
      )
    );
  END IF;

  RETURN QUERY
  SELECT
    v_recipe.id AS recipe_id,
    v_recipe.restaurant_id,
    v_recipe.menu_item_id,
    v_menu_item.name AS menu_item_name,
    v_recipe.ingredient_id,
    v_ingredient.name AS ingredient_name,
    v_ingredient.unit AS ingredient_unit,
    v_recipe.quantity_g,
    v_recipe.updated_at AS last_updated;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;
