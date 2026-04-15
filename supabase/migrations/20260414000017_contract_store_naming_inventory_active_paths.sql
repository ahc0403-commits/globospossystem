-- ============================================================
-- Contract phase: rename active inventory RPC inputs to store naming
-- 2026-04-14
-- Scope:
-- - ingredient catalog/read-write
-- - recipe catalog/upsert
-- - restock / waste
-- - physical count read/apply
-- - transaction visibility
-- Notes:
-- - physical schema still uses restaurant_id during coexistence
-- - delete/archive flows remain separate follow-up work
-- ============================================================

DROP FUNCTION IF EXISTS public.get_inventory_ingredient_catalog(uuid);
DROP FUNCTION IF EXISTS public.create_inventory_item(uuid, text, text, numeric, numeric, numeric, text);
DROP FUNCTION IF EXISTS public.update_inventory_item(uuid, uuid, jsonb);
DROP FUNCTION IF EXISTS public.get_inventory_recipe_catalog(uuid, uuid);
DROP FUNCTION IF EXISTS public.upsert_inventory_recipe_line(uuid, uuid, uuid, numeric);
DROP FUNCTION IF EXISTS public.restock_inventory_item(uuid, uuid, numeric, text);
DROP FUNCTION IF EXISTS public.record_inventory_waste(uuid, uuid, numeric, text);
DROP FUNCTION IF EXISTS public.get_inventory_physical_count_sheet(uuid, date);
DROP FUNCTION IF EXISTS public.apply_inventory_physical_count_line(uuid, date, uuid, numeric, text);
DROP FUNCTION IF EXISTS public.get_inventory_transaction_visibility(uuid, timestamptz, timestamptz);

CREATE OR REPLACE FUNCTION public.get_inventory_ingredient_catalog(
  p_store_id UUID
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
     AND v_actor.restaurant_id <> p_store_id THEN
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
  WHERE ii.restaurant_id = p_store_id
  ORDER BY lower(ii.name), ii.created_at;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.create_inventory_item(
  p_store_id UUID,
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
     AND v_actor.restaurant_id <> p_store_id THEN
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
    WHERE ii.restaurant_id = p_store_id
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
    p_store_id,
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
      'store_id', p_store_id,
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
  p_store_id UUID,
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
     AND v_actor.restaurant_id <> p_store_id THEN
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
    AND restaurant_id = p_store_id
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
    WHERE ii.restaurant_id = p_store_id
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
    AND restaurant_id = p_store_id
  RETURNING * INTO v_updated;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'inventory_item_updated',
    'inventory_items',
    v_updated.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'changed_fields', to_jsonb(v_changed_fields),
      'old_values', v_old_values,
      'new_values', v_new_values
    )
  );

  RETURN v_updated;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.get_inventory_recipe_catalog(
  p_store_id UUID,
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
     AND v_actor.restaurant_id <> p_store_id THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_FORBIDDEN';
  END IF;

  IF p_menu_item_id IS NOT NULL AND NOT EXISTS (
    SELECT 1
    FROM public.menu_items mi
    WHERE mi.id = p_menu_item_id
      AND mi.restaurant_id = p_store_id
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
  WHERE mr.restaurant_id = p_store_id
    AND (p_menu_item_id IS NULL OR mr.menu_item_id = p_menu_item_id)
  ORDER BY lower(mi.name), lower(ii.name), mr.created_at;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

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
     AND v_actor.restaurant_id <> p_store_id THEN
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
    AND mi.restaurant_id = p_store_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_MENU_ITEM_NOT_FOUND';
  END IF;

  SELECT ii.*
  INTO v_ingredient
  FROM public.inventory_items ii
  WHERE ii.id = p_ingredient_id
    AND ii.restaurant_id = p_store_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_INGREDIENT_NOT_FOUND';
  END IF;

  IF v_ingredient.unit <> 'g' THEN
    RAISE EXCEPTION 'INVENTORY_RECIPE_INGREDIENT_UNIT_UNSUPPORTED';
  END IF;

  SELECT mr.*
  INTO v_existing
  FROM public.menu_recipes mr
  WHERE mr.restaurant_id = p_store_id
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
          'store_id', p_store_id,
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
      p_store_id,
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
        'store_id', p_store_id,
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

CREATE OR REPLACE FUNCTION public.restock_inventory_item(
  p_store_id UUID,
  p_ingredient_id UUID,
  p_quantity_g DECIMAL(10,3),
  p_note TEXT DEFAULT NULL
) RETURNS VOID AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_ingredient public.inventory_items%ROWTYPE;
  v_new_stock DECIMAL(10,3);
BEGIN
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
     AND v_actor.restaurant_id <> p_store_id THEN
    RAISE EXCEPTION 'INVENTORY_RESTOCK_FORBIDDEN';
  END IF;

  IF p_quantity_g IS NULL OR p_quantity_g <= 0 THEN
    RAISE EXCEPTION 'INVENTORY_RESTOCK_QUANTITY_INVALID';
  END IF;

  SELECT *
  INTO v_ingredient
  FROM public.inventory_items
  WHERE id = p_ingredient_id
    AND restaurant_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_RESTOCK_INGREDIENT_NOT_FOUND';
  END IF;

  v_new_stock := COALESCE(v_ingredient.current_stock, 0) + p_quantity_g;

  UPDATE public.inventory_items
  SET current_stock = v_new_stock,
      updated_at = now()
  WHERE id = p_ingredient_id
    AND restaurant_id = p_store_id;

  INSERT INTO public.inventory_transactions (
    restaurant_id, ingredient_id, transaction_type,
    quantity_g, reference_type, note, created_by
  ) VALUES (
    p_store_id, p_ingredient_id, 'restock',
    p_quantity_g, 'manual', p_note, v_actor.id
  );

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'inventory_restocked',
    'inventory_items',
    p_ingredient_id,
    jsonb_build_object(
      'store_id', p_store_id,
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

CREATE OR REPLACE FUNCTION public.record_inventory_waste(
  p_store_id UUID,
  p_ingredient_id UUID,
  p_quantity_g DECIMAL(10,3),
  p_note TEXT DEFAULT NULL
) RETURNS VOID AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_ingredient public.inventory_items%ROWTYPE;
  v_new_stock DECIMAL(10,3);
BEGIN
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
     AND v_actor.restaurant_id <> p_store_id THEN
    RAISE EXCEPTION 'INVENTORY_WASTE_FORBIDDEN';
  END IF;

  IF p_quantity_g IS NULL OR p_quantity_g <= 0 THEN
    RAISE EXCEPTION 'INVENTORY_WASTE_QUANTITY_INVALID';
  END IF;

  SELECT *
  INTO v_ingredient
  FROM public.inventory_items
  WHERE id = p_ingredient_id
    AND restaurant_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_WASTE_INGREDIENT_NOT_FOUND';
  END IF;

  v_new_stock := COALESCE(v_ingredient.current_stock, 0) - p_quantity_g;

  UPDATE public.inventory_items
  SET current_stock = v_new_stock,
      updated_at = now()
  WHERE id = p_ingredient_id
    AND restaurant_id = p_store_id;

  INSERT INTO public.inventory_transactions (
    restaurant_id, ingredient_id, transaction_type,
    quantity_g, reference_type, note, created_by
  ) VALUES (
    p_store_id, p_ingredient_id, 'waste',
    -p_quantity_g, 'manual', p_note, v_actor.id
  );

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'inventory_waste_recorded',
    'inventory_items',
    p_ingredient_id,
    jsonb_build_object(
      'store_id', p_store_id,
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

CREATE OR REPLACE FUNCTION public.get_inventory_physical_count_sheet(
  p_store_id UUID,
  p_count_date DATE
) RETURNS TABLE (
  ingredient_id UUID,
  ingredient_name TEXT,
  ingredient_unit TEXT,
  theoretical_quantity_g DECIMAL(12,3),
  actual_quantity_g DECIMAL(12,3),
  variance_quantity_g DECIMAL(12,3),
  count_date DATE,
  last_updated TIMESTAMPTZ
) AS $$
DECLARE
  v_actor public.users%ROWTYPE;
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'INVENTORY_PHYSICAL_COUNT_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_store_id THEN
    RAISE EXCEPTION 'INVENTORY_PHYSICAL_COUNT_FORBIDDEN';
  END IF;

  IF p_count_date IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_PHYSICAL_COUNT_DATE_REQUIRED';
  END IF;

  RETURN QUERY
  SELECT
    ii.id AS ingredient_id,
    ii.name AS ingredient_name,
    ii.unit AS ingredient_unit,
    ii.current_stock AS theoretical_quantity_g,
    ipc.actual_quantity_g,
    ipc.variance_g AS variance_quantity_g,
    p_count_date AS count_date,
    COALESCE(ipc.updated_at, ipc.created_at, ii.updated_at) AS last_updated
  FROM public.inventory_items ii
  LEFT JOIN public.inventory_physical_counts ipc
    ON ipc.restaurant_id = p_store_id
   AND ipc.ingredient_id = ii.id
   AND ipc.count_date = p_count_date
  WHERE ii.restaurant_id = p_store_id
  ORDER BY lower(ii.name), ii.created_at;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.apply_inventory_physical_count_line(
  p_store_id UUID,
  p_count_date DATE,
  p_ingredient_id UUID,
  p_actual_quantity_g DECIMAL(12,3),
  p_note TEXT DEFAULT NULL
) RETURNS TABLE (
  ingredient_id UUID,
  count_date DATE,
  theoretical_quantity_g DECIMAL(12,3),
  actual_quantity_g DECIMAL(12,3),
  variance_quantity_g DECIMAL(12,3),
  inventory_transaction_id UUID,
  last_updated TIMESTAMPTZ
) AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_ingredient public.inventory_items%ROWTYPE;
  v_existing_count public.inventory_physical_counts%ROWTYPE;
  v_count_row public.inventory_physical_counts%ROWTYPE;
  v_transaction public.inventory_transactions%ROWTYPE;
  v_old_stock DECIMAL(12,3);
  v_variance DECIMAL(12,3);
  v_note TEXT := NULLIF(btrim(COALESCE(p_note, '')), '');
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'INVENTORY_PHYSICAL_COUNT_WRITE_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_store_id THEN
    RAISE EXCEPTION 'INVENTORY_PHYSICAL_COUNT_WRITE_FORBIDDEN';
  END IF;

  IF p_count_date IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_PHYSICAL_COUNT_DATE_REQUIRED';
  END IF;

  IF p_ingredient_id IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_PHYSICAL_COUNT_INGREDIENT_REQUIRED';
  END IF;

  IF p_actual_quantity_g IS NULL OR p_actual_quantity_g < 0 THEN
    RAISE EXCEPTION 'INVENTORY_PHYSICAL_COUNT_ACTUAL_INVALID';
  END IF;

  SELECT ii.*
  INTO v_ingredient
  FROM public.inventory_items ii
  WHERE ii.id = p_ingredient_id
    AND ii.restaurant_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_PHYSICAL_COUNT_INGREDIENT_NOT_FOUND';
  END IF;

  v_old_stock := v_ingredient.current_stock;
  v_variance := p_actual_quantity_g - v_old_stock;

  SELECT ipc.*
  INTO v_existing_count
  FROM public.inventory_physical_counts ipc
  WHERE ipc.restaurant_id = p_store_id
    AND ipc.ingredient_id = p_ingredient_id
    AND ipc.count_date = p_count_date
  FOR UPDATE;

  INSERT INTO public.inventory_physical_counts (
    restaurant_id,
    ingredient_id,
    count_date,
    actual_quantity_g,
    theoretical_quantity_g,
    variance_g,
    counted_by,
    updated_at
  )
  VALUES (
    p_store_id,
    p_ingredient_id,
    p_count_date,
    p_actual_quantity_g,
    v_old_stock,
    v_variance,
    auth.uid(),
    now()
  )
  ON CONFLICT ON CONSTRAINT inventory_physical_counts_ingredient_id_count_date_key
  DO UPDATE SET
    actual_quantity_g = EXCLUDED.actual_quantity_g,
    theoretical_quantity_g = EXCLUDED.theoretical_quantity_g,
    variance_g = EXCLUDED.variance_g,
    counted_by = EXCLUDED.counted_by,
    updated_at = now()
  RETURNING * INTO v_count_row;

  UPDATE public.inventory_items ii
  SET current_stock = p_actual_quantity_g,
      updated_at = now()
  WHERE ii.id = p_ingredient_id
    AND ii.restaurant_id = p_store_id;

  INSERT INTO public.inventory_transactions (
    restaurant_id,
    ingredient_id,
    transaction_type,
    quantity_g,
    reference_type,
    reference_id,
    note,
    created_by
  )
  VALUES (
    p_store_id,
    p_ingredient_id,
    'adjust',
    v_variance,
    'physical_count',
    v_count_row.id,
    COALESCE(
      v_note,
      format('실재고 실사 (%s)', to_char(p_count_date, 'YYYY-MM-DD'))
    ),
    auth.uid()
  )
  RETURNING * INTO v_transaction;

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'inventory_physical_count_applied',
    'inventory_physical_counts',
    v_count_row.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'ingredient_id', p_ingredient_id,
      'count_date', p_count_date,
      'old_stock', v_old_stock,
      'new_stock', p_actual_quantity_g,
      'variance_quantity_g', v_variance,
      'note', v_note,
      'previous_count', CASE
        WHEN v_existing_count.id IS NULL THEN NULL
        ELSE jsonb_build_object(
          'actual_quantity_g', v_existing_count.actual_quantity_g,
          'theoretical_quantity_g', v_existing_count.theoretical_quantity_g,
          'variance_g', v_existing_count.variance_g
        )
      END
    )
  );

  RETURN QUERY
  SELECT
    p_ingredient_id AS ingredient_id,
    p_count_date AS count_date,
    v_old_stock AS theoretical_quantity_g,
    p_actual_quantity_g AS actual_quantity_g,
    v_variance AS variance_quantity_g,
    v_transaction.id AS inventory_transaction_id,
    v_count_row.updated_at AS last_updated;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.get_inventory_transaction_visibility(
  p_store_id UUID,
  p_from TIMESTAMPTZ,
  p_to TIMESTAMPTZ
) RETURNS TABLE (
  id UUID,
  restaurant_id UUID,
  ingredient_id UUID,
  ingredient_name TEXT,
  ingredient_unit TEXT,
  transaction_type TEXT,
  quantity_g DECIMAL(12,3),
  reference_type TEXT,
  reference_id UUID,
  note TEXT,
  created_at TIMESTAMPTZ
) AS $$
DECLARE
  v_actor public.users%ROWTYPE;
BEGIN
  SELECT u.*
  INTO v_actor
  FROM public.users u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin') THEN
    RAISE EXCEPTION 'INVENTORY_TRANSACTION_VISIBILITY_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_store_id THEN
    RAISE EXCEPTION 'INVENTORY_TRANSACTION_VISIBILITY_FORBIDDEN';
  END IF;

  IF p_from IS NULL OR p_to IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_TRANSACTION_VISIBILITY_RANGE_REQUIRED';
  END IF;

  IF p_from > p_to THEN
    RAISE EXCEPTION 'INVENTORY_TRANSACTION_VISIBILITY_RANGE_INVALID';
  END IF;

  RETURN QUERY
  SELECT
    it.id,
    it.restaurant_id,
    it.ingredient_id,
    ii.name AS ingredient_name,
    ii.unit AS ingredient_unit,
    it.transaction_type,
    it.quantity_g,
    it.reference_type,
    it.reference_id,
    it.note,
    it.created_at
  FROM public.inventory_transactions it
  JOIN public.inventory_items ii
    ON ii.id = it.ingredient_id
   AND ii.restaurant_id = it.restaurant_id
  WHERE it.restaurant_id = p_store_id
    AND it.created_at >= p_from
    AND it.created_at <= p_to
  ORDER BY it.created_at DESC, ii.name;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;
