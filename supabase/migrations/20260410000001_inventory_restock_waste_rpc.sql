-- ============================================================
-- Inventory Write Path Hardening: Restock + Waste RPCs
-- 2026-04-10
-- Bounded scope:
--   - restock_inventory_item: atomic restock (stock update + transaction + audit)
--   - record_inventory_waste: atomic waste recording (stock deduction + transaction + audit)
-- Out of scope:
--   - delete RPCs for ingredients/recipes
--   - unit conversion beyond gram
--   - automatic deduction redesign
-- ============================================================

-- ─── Restock RPC ────────────────────────────────
CREATE OR REPLACE FUNCTION public.restock_inventory_item(
  p_restaurant_id UUID,
  p_ingredient_id UUID,
  p_quantity_g    DECIMAL(10,3),
  p_note          TEXT DEFAULT NULL
) RETURNS VOID AS $$
DECLARE
  v_actor       public.users%ROWTYPE;
  v_ingredient  public.inventory_items%ROWTYPE;
  v_new_stock   DECIMAL(10,3);
BEGIN
  -- Actor validation
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'INVENTORY_RESTOCK_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_restaurant_id THEN
    RAISE EXCEPTION 'INVENTORY_RESTOCK_FORBIDDEN';
  END IF;

  -- Input validation
  IF p_quantity_g IS NULL OR p_quantity_g <= 0 THEN
    RAISE EXCEPTION 'INVENTORY_RESTOCK_QUANTITY_INVALID';
  END IF;

  -- Lock ingredient row
  SELECT *
  INTO v_ingredient
  FROM public.inventory_items
  WHERE id = p_ingredient_id
    AND restaurant_id = p_restaurant_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_RESTOCK_INGREDIENT_NOT_FOUND';
  END IF;

  v_new_stock := COALESCE(v_ingredient.current_stock, 0) + p_quantity_g;

  -- Atomic stock update
  UPDATE public.inventory_items
  SET current_stock = v_new_stock,
      updated_at    = now()
  WHERE id = p_ingredient_id
    AND restaurant_id = p_restaurant_id;

  -- Transaction record
  INSERT INTO public.inventory_transactions (
    restaurant_id, ingredient_id, transaction_type,
    quantity_g, reference_type, note, created_by
  ) VALUES (
    p_restaurant_id, p_ingredient_id, 'restock',
    p_quantity_g, 'manual', p_note, v_actor.id
  );

  -- Audit log
  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'inventory_restocked',
    'inventory_items',
    p_ingredient_id,
    jsonb_build_object(
      'restaurant_id', p_restaurant_id,
      'ingredient_name', v_ingredient.name,
      'quantity_g', p_quantity_g,
      'old_stock', COALESCE(v_ingredient.current_stock, 0),
      'new_stock', v_new_stock,
      'note', p_note
    )
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;
-- ─── Waste RPC ──────────────────────────────────
CREATE OR REPLACE FUNCTION public.record_inventory_waste(
  p_restaurant_id UUID,
  p_ingredient_id UUID,
  p_quantity_g    DECIMAL(10,3),
  p_note          TEXT DEFAULT NULL
) RETURNS VOID AS $$
DECLARE
  v_actor       public.users%ROWTYPE;
  v_ingredient  public.inventory_items%ROWTYPE;
  v_new_stock   DECIMAL(10,3);
BEGIN
  -- Actor validation
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'INVENTORY_WASTE_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_restaurant_id THEN
    RAISE EXCEPTION 'INVENTORY_WASTE_FORBIDDEN';
  END IF;

  -- Input validation
  IF p_quantity_g IS NULL OR p_quantity_g <= 0 THEN
    RAISE EXCEPTION 'INVENTORY_WASTE_QUANTITY_INVALID';
  END IF;

  -- Lock ingredient row
  SELECT *
  INTO v_ingredient
  FROM public.inventory_items
  WHERE id = p_ingredient_id
    AND restaurant_id = p_restaurant_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_WASTE_INGREDIENT_NOT_FOUND';
  END IF;

  v_new_stock := COALESCE(v_ingredient.current_stock, 0) - p_quantity_g;

  -- Allow negative stock (real-world discrepancy) but warn via audit
  UPDATE public.inventory_items
  SET current_stock = v_new_stock,
      updated_at    = now()
  WHERE id = p_ingredient_id
    AND restaurant_id = p_restaurant_id;

  -- Transaction record (negative quantity for waste)
  INSERT INTO public.inventory_transactions (
    restaurant_id, ingredient_id, transaction_type,
    quantity_g, reference_type, note, created_by
  ) VALUES (
    p_restaurant_id, p_ingredient_id, 'waste',
    -p_quantity_g, 'manual', p_note, v_actor.id
  );

  -- Audit log
  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'inventory_waste_recorded',
    'inventory_items',
    p_ingredient_id,
    jsonb_build_object(
      'restaurant_id', p_restaurant_id,
      'ingredient_name', v_ingredient.name,
      'quantity_g', p_quantity_g,
      'old_stock', COALESCE(v_ingredient.current_stock, 0),
      'new_stock', v_new_stock,
      'note', p_note,
      'went_negative', v_new_stock < 0
    )
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;
