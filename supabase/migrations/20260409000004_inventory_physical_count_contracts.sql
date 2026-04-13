-- ============================================================
-- POS Inventory Physical Count contract-readiness
-- 2026-04-09
-- Bounded scope:
-- - canonical date-based physical count sheet read
-- - atomic per-line physical count apply
-- - server-owned validation
-- - minimal physical-count audit trace
-- Out of scope:
-- - count session lifecycle/finalize/reset
-- - restock/reporting/recipe redesign
-- ============================================================

ALTER TABLE public.inventory_physical_counts
  ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT now();

CREATE OR REPLACE FUNCTION public.get_inventory_physical_count_sheet(
  p_restaurant_id UUID,
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
     AND v_actor.restaurant_id <> p_restaurant_id THEN
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
    ON ipc.restaurant_id = p_restaurant_id
   AND ipc.ingredient_id = ii.id
   AND ipc.count_date = p_count_date
  WHERE ii.restaurant_id = p_restaurant_id
  ORDER BY lower(ii.name), ii.created_at;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.apply_inventory_physical_count_line(
  p_restaurant_id UUID,
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
     AND v_actor.restaurant_id <> p_restaurant_id THEN
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
    AND ii.restaurant_id = p_restaurant_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_PHYSICAL_COUNT_INGREDIENT_NOT_FOUND';
  END IF;

  v_old_stock := v_ingredient.current_stock;
  v_variance := p_actual_quantity_g - v_old_stock;

  SELECT ipc.*
  INTO v_existing_count
  FROM public.inventory_physical_counts ipc
  WHERE ipc.restaurant_id = p_restaurant_id
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
    p_restaurant_id,
    p_ingredient_id,
    p_count_date,
    p_actual_quantity_g,
    v_old_stock,
    v_variance,
    auth.uid(),
    now()
  )
  ON CONFLICT (ingredient_id, count_date)
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
    AND ii.restaurant_id = p_restaurant_id;

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
    p_restaurant_id,
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
      'restaurant_id', p_restaurant_id,
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
