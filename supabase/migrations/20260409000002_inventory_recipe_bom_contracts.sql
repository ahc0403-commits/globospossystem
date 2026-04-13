-- ============================================================
-- POS Inventory Recipe/BOM Mapping contract-readiness
-- 2026-04-09
-- Bounded scope:
-- - canonical recipe mapping read
-- - create/update recipe mapping upsert
-- - server-owned validation
-- - recipe-specific audit logging
-- Out of scope:
-- - delete/archive
-- - restock / physical count
-- - transaction report product work
-- - full unit conversion redesign
-- - automatic deduction redesign
-- ============================================================

ALTER TABLE public.menu_recipes
  ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT now();

CREATE OR REPLACE FUNCTION public.get_inventory_recipe_catalog(
  p_restaurant_id UUID,
  p_menu_item_id UUID DEFAULT NULL
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
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_restaurant_id THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_FORBIDDEN';
  END IF;

  IF p_menu_item_id IS NOT NULL AND NOT EXISTS (
    SELECT 1
    FROM public.menu_items mi
    WHERE mi.id = p_menu_item_id
      AND mi.restaurant_id = p_restaurant_id
  ) THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_MENU_ITEM_NOT_FOUND';
  END IF;

  RETURN QUERY
  SELECT
    mr.id AS recipe_id,
    mr.restaurant_id,
    mr.menu_item_id,
    mi.name AS menu_item_name,
    mr.ingredient_id,
    ii.name AS ingredient_name,
    ii.unit AS ingredient_unit,
    mr.quantity_g,
    mr.updated_at AS last_updated
  FROM public.menu_recipes mr
  JOIN public.menu_items mi
    ON mi.id = mr.menu_item_id
   AND mi.restaurant_id = mr.restaurant_id
  JOIN public.inventory_items ii
    ON ii.id = mr.ingredient_id
   AND ii.restaurant_id = mr.restaurant_id
  WHERE mr.restaurant_id = p_restaurant_id
    AND (p_menu_item_id IS NULL OR mr.menu_item_id = p_menu_item_id)
  ORDER BY lower(mi.name), lower(ii.name), mr.created_at;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

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
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
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

  SELECT *
  INTO v_menu_item
  FROM public.menu_items
  WHERE id = p_menu_item_id
    AND restaurant_id = p_restaurant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_MENU_ITEM_NOT_FOUND';
  END IF;

  SELECT *
  INTO v_ingredient
  FROM public.inventory_items
  WHERE id = p_ingredient_id
    AND restaurant_id = p_restaurant_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_INGREDIENT_NOT_FOUND';
  END IF;

  -- v1 unit policy: quantity_g is defined in grams, so only gram-unit ingredients
  -- are bindable in this bounded wave.
  IF v_ingredient.unit <> 'g' THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_INGREDIENT_UNIT_UNSUPPORTED';
  END IF;

  SELECT *
  INTO v_existing
  FROM public.menu_recipes
  WHERE restaurant_id = p_restaurant_id
    AND menu_item_id = p_menu_item_id
    AND ingredient_id = p_ingredient_id
  FOR UPDATE;

  IF FOUND THEN
    IF v_existing.quantity_g IS DISTINCT FROM p_quantity_g THEN
      v_changed_fields := ARRAY['quantity_g'];
      v_old_values := jsonb_build_object('quantity_g', v_existing.quantity_g);
      v_new_values := jsonb_build_object('quantity_g', p_quantity_g);

      UPDATE public.menu_recipes
      SET quantity_g = p_quantity_g,
          updated_at = now()
      WHERE id = v_existing.id
      RETURNING * INTO v_recipe;

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
