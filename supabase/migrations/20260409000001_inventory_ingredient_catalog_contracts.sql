-- ============================================================
-- POS Inventory Ingredient Catalog contract-readiness
-- 2026-04-09
-- Bounded scope:
-- - canonical ingredient catalog read
-- - create ingredient
-- - update ingredient metadata
-- - inventory-specific audit logging
-- Out of scope:
-- - delete/archive
-- - restock / physical count
-- - recipe bindings
-- - transaction report product work
-- - automatic deduction redesign
-- ============================================================

CREATE UNIQUE INDEX IF NOT EXISTS idx_inventory_items_restaurant_name_ci
  ON public.inventory_items (restaurant_id, lower(btrim(name)));

CREATE OR REPLACE FUNCTION public.get_inventory_ingredient_catalog(
  p_restaurant_id UUID
) RETURNS TABLE (
  id UUID,
  restaurant_id UUID,
  name TEXT,
  unit TEXT,
  current_stock DECIMAL(12,3),
  reorder_point DECIMAL(12,3),
  cost_per_unit DECIMAL(12,2),
  supplier_name TEXT,
  needs_reorder BOOLEAN,
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
    RAISE EXCEPTION 'INVENTORY_CATALOG_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_restaurant_id THEN
    RAISE EXCEPTION 'INVENTORY_CATALOG_FORBIDDEN';
  END IF;

  RETURN QUERY
  SELECT
    ii.id,
    ii.restaurant_id,
    ii.name,
    ii.unit,
    ii.current_stock,
    ii.reorder_point,
    ii.cost_per_unit,
    ii.supplier_name,
    CASE
      WHEN ii.reorder_point IS NOT NULL AND ii.current_stock <= ii.reorder_point
        THEN TRUE
      ELSE FALSE
    END AS needs_reorder,
    ii.updated_at AS last_updated
  FROM public.inventory_items ii
  WHERE ii.restaurant_id = p_restaurant_id
  ORDER BY lower(ii.name), ii.created_at;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.create_inventory_item(
  p_restaurant_id UUID,
  p_name TEXT,
  p_unit TEXT,
  p_current_stock DECIMAL(12,3) DEFAULT NULL,
  p_reorder_point DECIMAL(12,3) DEFAULT NULL,
  p_cost_per_unit DECIMAL(12,2) DEFAULT NULL,
  p_supplier_name TEXT DEFAULT NULL
) RETURNS public.inventory_items AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_created public.inventory_items%ROWTYPE;
  v_name TEXT := btrim(COALESCE(p_name, ''));
  v_unit TEXT := btrim(COALESCE(p_unit, ''));
  v_current_stock DECIMAL(12,3) := COALESCE(p_current_stock, 0);
  v_reorder_point DECIMAL(12,3) := p_reorder_point;
  v_cost_per_unit DECIMAL(12,2) := p_cost_per_unit;
  v_supplier_name TEXT := NULLIF(btrim(COALESCE(p_supplier_name, '')), '');
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_WRITE_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_restaurant_id THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_WRITE_FORBIDDEN';
  END IF;

  IF v_name = '' THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_NAME_REQUIRED';
  END IF;

  IF v_unit NOT IN ('g', 'ml', 'ea') THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_UNIT_INVALID';
  END IF;

  IF v_current_stock < 0 THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_CURRENT_STOCK_INVALID';
  END IF;

  IF v_reorder_point IS NOT NULL AND v_reorder_point < 0 THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_REORDER_POINT_INVALID';
  END IF;

  IF v_cost_per_unit IS NOT NULL AND v_cost_per_unit < 0 THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_COST_INVALID';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.inventory_items ii
    WHERE ii.restaurant_id = p_restaurant_id
      AND lower(btrim(ii.name)) = lower(v_name)
  ) THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_NAME_DUPLICATE';
  END IF;

  INSERT INTO public.inventory_items (
    restaurant_id,
    name,
    unit,
    current_stock,
    reorder_point,
    cost_per_unit,
    supplier_name,
    updated_at
  )
  VALUES (
    p_restaurant_id,
    v_name,
    v_unit,
    v_current_stock,
    v_reorder_point,
    v_cost_per_unit,
    v_supplier_name,
    now()
  )
  RETURNING * INTO v_created;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'inventory_item_created',
    'inventory_items',
    v_created.id,
    jsonb_build_object(
      'restaurant_id', p_restaurant_id,
      'new_values', jsonb_build_object(
        'name', v_created.name,
        'unit', v_created.unit,
        'current_stock', v_created.current_stock,
        'reorder_point', v_created.reorder_point,
        'cost_per_unit', v_created.cost_per_unit,
        'supplier_name', v_created.supplier_name
      )
    )
  );

  RETURN v_created;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.update_inventory_item(
  p_item_id UUID,
  p_restaurant_id UUID,
  p_patch JSONB
) RETURNS public.inventory_items AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_existing public.inventory_items%ROWTYPE;
  v_updated public.inventory_items%ROWTYPE;
  v_supported_keys CONSTANT TEXT[] := ARRAY[
    'name',
    'unit',
    'current_stock',
    'reorder_point',
    'cost_per_unit',
    'supplier_name'
  ];
  v_key TEXT;
  v_name TEXT;
  v_unit TEXT;
  v_current_stock DECIMAL(12,3);
  v_reorder_point DECIMAL(12,3);
  v_cost_per_unit DECIMAL(12,2);
  v_supplier_name TEXT;
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
    RAISE EXCEPTION 'INVENTORY_ITEM_WRITE_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_restaurant_id THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_WRITE_FORBIDDEN';
  END IF;

  IF p_patch IS NULL OR jsonb_typeof(p_patch) <> 'object' THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_PATCH_INVALID';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM jsonb_object_keys(p_patch) AS k(key)
    WHERE k.key = ANY(v_supported_keys)
  ) THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_PATCH_EMPTY';
  END IF;

  FOR v_key IN
    SELECT key
    FROM jsonb_object_keys(p_patch) AS k(key)
  LOOP
    IF NOT (v_key = ANY(v_supported_keys)) THEN
      RAISE EXCEPTION 'INVENTORY_ITEM_PATCH_UNSUPPORTED';
    END IF;
  END LOOP;

  SELECT *
  INTO v_existing
  FROM public.inventory_items
  WHERE id = p_item_id
    AND restaurant_id = p_restaurant_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_NOT_FOUND';
  END IF;

  v_name := v_existing.name;
  v_unit := v_existing.unit;
  v_current_stock := v_existing.current_stock;
  v_reorder_point := v_existing.reorder_point;
  v_cost_per_unit := v_existing.cost_per_unit;
  v_supplier_name := v_existing.supplier_name;

  IF p_patch ? 'name' THEN
    v_name := btrim(COALESCE(p_patch->>'name', ''));
    IF v_name = '' THEN
      RAISE EXCEPTION 'INVENTORY_ITEM_NAME_REQUIRED';
    END IF;
  END IF;

  IF p_patch ? 'unit' THEN
    v_unit := btrim(COALESCE(p_patch->>'unit', ''));
    IF v_unit NOT IN ('g', 'ml', 'ea') THEN
      RAISE EXCEPTION 'INVENTORY_ITEM_UNIT_INVALID';
    END IF;
  END IF;

  IF p_patch ? 'current_stock' THEN
    IF jsonb_typeof(p_patch->'current_stock') = 'null' THEN
      RAISE EXCEPTION 'INVENTORY_ITEM_CURRENT_STOCK_REQUIRED';
    END IF;
    v_current_stock := (p_patch->>'current_stock')::DECIMAL(12,3);
    IF v_current_stock < 0 THEN
      RAISE EXCEPTION 'INVENTORY_ITEM_CURRENT_STOCK_INVALID';
    END IF;
  END IF;

  IF p_patch ? 'reorder_point' THEN
    IF jsonb_typeof(p_patch->'reorder_point') = 'null' THEN
      v_reorder_point := NULL;
    ELSE
      v_reorder_point := (p_patch->>'reorder_point')::DECIMAL(12,3);
      IF v_reorder_point < 0 THEN
        RAISE EXCEPTION 'INVENTORY_ITEM_REORDER_POINT_INVALID';
      END IF;
    END IF;
  END IF;

  IF p_patch ? 'cost_per_unit' THEN
    IF jsonb_typeof(p_patch->'cost_per_unit') = 'null' THEN
      v_cost_per_unit := NULL;
    ELSE
      v_cost_per_unit := (p_patch->>'cost_per_unit')::DECIMAL(12,2);
      IF v_cost_per_unit < 0 THEN
        RAISE EXCEPTION 'INVENTORY_ITEM_COST_INVALID';
      END IF;
    END IF;
  END IF;

  IF p_patch ? 'supplier_name' THEN
    IF jsonb_typeof(p_patch->'supplier_name') = 'null' THEN
      v_supplier_name := NULL;
    ELSE
      v_supplier_name := NULLIF(btrim(p_patch->>'supplier_name'), '');
    END IF;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.inventory_items ii
    WHERE ii.restaurant_id = p_restaurant_id
      AND ii.id <> p_item_id
      AND lower(btrim(ii.name)) = lower(v_name)
  ) THEN
    RAISE EXCEPTION 'INVENTORY_ITEM_NAME_DUPLICATE';
  END IF;

  IF v_existing.name IS DISTINCT FROM v_name THEN
    v_changed_fields := array_append(v_changed_fields, 'name');
    v_old_values := v_old_values || jsonb_build_object('name', v_existing.name);
    v_new_values := v_new_values || jsonb_build_object('name', v_name);
  END IF;
  IF v_existing.unit IS DISTINCT FROM v_unit THEN
    v_changed_fields := array_append(v_changed_fields, 'unit');
    v_old_values := v_old_values || jsonb_build_object('unit', v_existing.unit);
    v_new_values := v_new_values || jsonb_build_object('unit', v_unit);
  END IF;
  IF v_existing.current_stock IS DISTINCT FROM v_current_stock THEN
    v_changed_fields := array_append(v_changed_fields, 'current_stock');
    v_old_values := v_old_values || jsonb_build_object('current_stock', v_existing.current_stock);
    v_new_values := v_new_values || jsonb_build_object('current_stock', v_current_stock);
  END IF;
  IF v_existing.reorder_point IS DISTINCT FROM v_reorder_point THEN
    v_changed_fields := array_append(v_changed_fields, 'reorder_point');
    v_old_values := v_old_values || jsonb_build_object('reorder_point', v_existing.reorder_point);
    v_new_values := v_new_values || jsonb_build_object('reorder_point', v_reorder_point);
  END IF;
  IF v_existing.cost_per_unit IS DISTINCT FROM v_cost_per_unit THEN
    v_changed_fields := array_append(v_changed_fields, 'cost_per_unit');
    v_old_values := v_old_values || jsonb_build_object('cost_per_unit', v_existing.cost_per_unit);
    v_new_values := v_new_values || jsonb_build_object('cost_per_unit', v_cost_per_unit);
  END IF;
  IF v_existing.supplier_name IS DISTINCT FROM v_supplier_name THEN
    v_changed_fields := array_append(v_changed_fields, 'supplier_name');
    v_old_values := v_old_values || jsonb_build_object('supplier_name', v_existing.supplier_name);
    v_new_values := v_new_values || jsonb_build_object('supplier_name', v_supplier_name);
  END IF;

  IF coalesce(array_length(v_changed_fields, 1), 0) = 0 THEN
    RETURN v_existing;
  END IF;

  UPDATE public.inventory_items
  SET name = v_name,
      unit = v_unit,
      current_stock = v_current_stock,
      reorder_point = v_reorder_point,
      cost_per_unit = v_cost_per_unit,
      supplier_name = v_supplier_name,
      updated_at = now()
  WHERE id = p_item_id
    AND restaurant_id = p_restaurant_id
  RETURNING * INTO v_updated;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'inventory_item_updated',
    'inventory_items',
    v_updated.id,
    jsonb_build_object(
      'restaurant_id', p_restaurant_id,
      'changed_fields', to_jsonb(v_changed_fields),
      'old_values', v_old_values,
      'new_values', v_new_values
    )
  );

  RETURN v_updated;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;
