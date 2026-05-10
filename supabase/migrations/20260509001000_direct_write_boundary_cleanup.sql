BEGIN;

-- Audit follow-up: remaining inventory and wage client writes must cross
-- explicit store-scoped RPC boundaries.

CREATE OR REPLACE FUNCTION public.delete_inventory_item(
  p_store_id UUID,
  p_item_id UUID
) RETURNS UUID AS $$
DECLARE
  v_existing public.inventory_items%ROWTYPE;
  v_deleted_id UUID;
BEGIN
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_STORE_REQUIRED';
  END IF;

  IF p_item_id IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_ID_REQUIRED';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(p_store_id);

  SELECT *
  INTO v_existing
  FROM public.inventory_items
  WHERE id = p_item_id
    AND restaurant_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_NOT_FOUND';
  END IF;

  DELETE FROM public.inventory_items
  WHERE id = v_existing.id
    AND restaurant_id = p_store_id
  RETURNING id INTO v_deleted_id;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'inventory_item_deleted',
    'inventory_items',
    v_existing.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'old_values', jsonb_build_object(
        'name', v_existing.name,
        'unit', v_existing.unit,
        'current_stock', v_existing.current_stock,
        'reorder_point', v_existing.reorder_point,
        'cost_per_unit', v_existing.cost_per_unit,
        'supplier_name', v_existing.supplier_name
      ),
      'deleted_at_utc', now()
    )
  );

  RETURN v_deleted_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.delete_inventory_recipe_line_by_keys(
  p_store_id UUID,
  p_menu_item_id UUID,
  p_ingredient_id UUID
) RETURNS UUID AS $$
DECLARE
  v_existing public.menu_recipes%ROWTYPE;
  v_deleted_id UUID;
BEGIN
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_STORE_REQUIRED';
  END IF;

  IF p_menu_item_id IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_MENU_ITEM_REQUIRED';
  END IF;

  IF p_ingredient_id IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_INGREDIENT_REQUIRED';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(p_store_id);

  SELECT *
  INTO v_existing
  FROM public.menu_recipes
  WHERE restaurant_id = p_store_id
    AND menu_item_id = p_menu_item_id
    AND ingredient_id = p_ingredient_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_NOT_FOUND';
  END IF;

  DELETE FROM public.menu_recipes
  WHERE id = v_existing.id
    AND restaurant_id = p_store_id
  RETURNING id INTO v_deleted_id;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'inventory_recipe_deleted',
    'menu_recipes',
    v_existing.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'menu_item_id', v_existing.menu_item_id,
      'ingredient_id', v_existing.ingredient_id,
      'old_values', jsonb_build_object(
        'quantity_g', v_existing.quantity_g
      ),
      'deleted_at_utc', now()
    )
  );

  RETURN v_deleted_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.upsert_staff_wage_config(
  p_store_id UUID,
  p_user_id UUID,
  p_wage_type TEXT,
  p_hourly_rate NUMERIC DEFAULT NULL,
  p_shift_rates JSONB DEFAULT '[]'::JSONB,
  p_effective_from DATE DEFAULT CURRENT_DATE
) RETURNS public.staff_wage_configs AS $$
DECLARE
  v_updated public.staff_wage_configs%ROWTYPE;
BEGIN
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'STAFF_WAGE_STORE_REQUIRED';
  END IF;

  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'STAFF_WAGE_USER_REQUIRED';
  END IF;

  IF p_wage_type NOT IN ('hourly', 'shift') THEN
    RAISE EXCEPTION 'STAFF_WAGE_TYPE_INVALID';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(p_store_id);

  IF NOT EXISTS (
    SELECT 1
    FROM public.users u
    WHERE u.id = p_user_id
      AND u.restaurant_id = p_store_id
  ) THEN
    RAISE EXCEPTION 'STAFF_WAGE_USER_STORE_MISMATCH';
  END IF;

  INSERT INTO public.staff_wage_configs (
    restaurant_id,
    user_id,
    wage_type,
    hourly_rate,
    shift_rates,
    effective_from,
    is_active
  ) VALUES (
    p_store_id,
    p_user_id,
    p_wage_type,
    p_hourly_rate,
    COALESCE(p_shift_rates, '[]'::JSONB),
    COALESCE(p_effective_from, CURRENT_DATE),
    TRUE
  )
  ON CONFLICT (user_id, effective_from) DO UPDATE
  SET restaurant_id = EXCLUDED.restaurant_id,
      wage_type = EXCLUDED.wage_type,
      hourly_rate = EXCLUDED.hourly_rate,
      shift_rates = EXCLUDED.shift_rates,
      is_active = TRUE
  RETURNING * INTO v_updated;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'upsert_staff_wage_config',
    'staff_wage_configs',
    v_updated.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'user_id', p_user_id,
      'wage_type', p_wage_type,
      'hourly_rate', p_hourly_rate,
      'effective_from', COALESCE(p_effective_from, CURRENT_DATE),
      'updated_at_utc', now()
    )
  );

  RETURN v_updated;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

GRANT EXECUTE ON FUNCTION public.delete_inventory_item(UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_inventory_recipe_line_by_keys(UUID, UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.upsert_staff_wage_config(UUID, UUID, TEXT, NUMERIC, JSONB, DATE) TO authenticated;

COMMIT;
