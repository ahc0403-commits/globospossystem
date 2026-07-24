BEGIN;

ALTER TABLE public.inventory_transactions
  ADD COLUMN IF NOT EXISTS stock_before numeric(12,3),
  ADD COLUMN IF NOT EXISTS stock_after numeric(12,3),
  ADD COLUMN IF NOT EXISTS effective_date date;

ALTER TABLE public.inventory_physical_counts
  ADD COLUMN IF NOT EXISTS note text;

UPDATE public.inventory_transactions
SET effective_date =
  (created_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date
WHERE effective_date IS NULL;

CREATE INDEX IF NOT EXISTS inventory_transactions_store_effective_date_idx
  ON public.inventory_transactions(restaurant_id, effective_date DESC, created_at DESC);

CREATE INDEX IF NOT EXISTS inventory_physical_counts_store_date_idx
  ON public.inventory_physical_counts(restaurant_id, count_date DESC, ingredient_id);

CREATE INDEX IF NOT EXISTS inventory_transactions_created_by_idx
  ON public.inventory_transactions(created_by)
  WHERE created_by IS NOT NULL;

CREATE INDEX IF NOT EXISTS inventory_transactions_employee_idx
  ON public.inventory_transactions(performed_by_employee_id)
  WHERE performed_by_employee_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS inventory_physical_counts_counted_by_idx
  ON public.inventory_physical_counts(counted_by)
  WHERE counted_by IS NOT NULL;

CREATE INDEX IF NOT EXISTS inventory_physical_counts_employee_idx
  ON public.inventory_physical_counts(performed_by_employee_id)
  WHERE performed_by_employee_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public.get_inventory_physical_count_sheet(
  p_store_id uuid,
  p_count_date date
) RETURNS TABLE (
  ingredient_id uuid,
  ingredient_name text,
  ingredient_unit text,
  theoretical_quantity_g numeric(12,3),
  actual_quantity_g numeric(12,3),
  variance_quantity_g numeric(12,3),
  count_date date,
  last_updated timestamptz
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
BEGIN
  SELECT actor.*
  INTO v_actor
  FROM public.users actor
  WHERE actor.auth_id = auth.uid()
    AND actor.is_active = true
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN (
    'admin',
    'store_admin',
    'brand_admin',
    'super_admin',
    'photo_objet_master',
    'photo_objet_store_admin'
  ) THEN
    RAISE EXCEPTION 'INVENTORY_PHYSICAL_COUNT_FORBIDDEN';
  END IF;

  IF p_store_id IS NULL OR p_count_date IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_PHYSICAL_COUNT_DATE_REQUIRED';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) scope(store_id)
       WHERE scope.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'INVENTORY_PHYSICAL_COUNT_FORBIDDEN';
  END IF;

  RETURN QUERY
  SELECT
    item.id,
    item.name,
    COALESCE(item.unit, 'ea'),
    COALESCE(
      count_row.theoretical_quantity_g,
      previous_count.actual_quantity_g,
      item.current_stock,
      0
    )::numeric(12,3),
    count_row.actual_quantity_g,
    count_row.variance_g,
    p_count_date,
    COALESCE(count_row.updated_at, count_row.created_at, item.updated_at)
  FROM public.inventory_items item
  LEFT JOIN public.inventory_physical_counts count_row
    ON count_row.restaurant_id = p_store_id
   AND count_row.ingredient_id = item.id
   AND count_row.count_date = p_count_date
  LEFT JOIN LATERAL (
    SELECT prior.actual_quantity_g
    FROM public.inventory_physical_counts prior
    WHERE prior.restaurant_id = p_store_id
      AND prior.ingredient_id = item.id
      AND prior.count_date < p_count_date
    ORDER BY prior.count_date DESC, prior.updated_at DESC
    LIMIT 1
  ) previous_count ON true
  WHERE item.restaurant_id = p_store_id
    AND item.is_active = true
  ORDER BY lower(item.name), item.created_at;
END;
$$;

CREATE OR REPLACE FUNCTION public.apply_inventory_physical_count_line(
  p_store_id uuid,
  p_count_date date,
  p_ingredient_id uuid,
  p_actual_quantity_g numeric(12,3),
  p_note text DEFAULT NULL
) RETURNS TABLE (
  ingredient_id uuid,
  count_date date,
  theoretical_quantity_g numeric(12,3),
  actual_quantity_g numeric(12,3),
  variance_quantity_g numeric(12,3),
  inventory_transaction_id uuid,
  last_updated timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_item public.inventory_items%ROWTYPE;
  v_existing_count public.inventory_physical_counts%ROWTYPE;
  v_count_row public.inventory_physical_counts%ROWTYPE;
  v_transaction public.inventory_transactions%ROWTYPE;
  v_hcm_today date := (now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date;
  v_baseline numeric(12,3);
  v_event_before numeric(12,3);
  v_variance numeric(12,3);
  v_event_change numeric(12,3);
  v_note text := NULLIF(btrim(COALESCE(p_note, '')), '');
BEGIN
  SELECT actor.*
  INTO v_actor
  FROM public.users actor
  WHERE actor.auth_id = auth.uid()
    AND actor.is_active = true
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN (
    'admin',
    'store_admin',
    'brand_admin',
    'super_admin',
    'photo_objet_master',
    'photo_objet_store_admin'
  ) THEN
    RAISE EXCEPTION 'INVENTORY_PHYSICAL_COUNT_WRITE_FORBIDDEN';
  END IF;

  IF p_store_id IS NULL
     OR p_count_date IS NULL
     OR p_count_date > v_hcm_today THEN
    RAISE EXCEPTION 'INVENTORY_PHYSICAL_COUNT_DATE_INVALID';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) scope(store_id)
       WHERE scope.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'INVENTORY_PHYSICAL_COUNT_WRITE_FORBIDDEN';
  END IF;

  IF p_ingredient_id IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_PHYSICAL_COUNT_INGREDIENT_REQUIRED';
  END IF;

  IF p_actual_quantity_g IS NULL OR p_actual_quantity_g < 0 THEN
    RAISE EXCEPTION 'INVENTORY_PHYSICAL_COUNT_ACTUAL_INVALID';
  END IF;

  SELECT item.*
  INTO v_item
  FROM public.inventory_items item
  WHERE item.id = p_ingredient_id
    AND item.restaurant_id = p_store_id
    AND item.is_active = true
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_PHYSICAL_COUNT_INGREDIENT_NOT_FOUND';
  END IF;

  SELECT count_row.*
  INTO v_existing_count
  FROM public.inventory_physical_counts count_row
  WHERE count_row.restaurant_id = p_store_id
    AND count_row.ingredient_id = p_ingredient_id
    AND count_row.count_date = p_count_date
  FOR UPDATE;

  IF v_existing_count.id IS NOT NULL THEN
    v_baseline := COALESCE(
      v_existing_count.theoretical_quantity_g,
      v_existing_count.actual_quantity_g,
      v_item.current_stock,
      0
    );
    v_event_before := COALESCE(
      v_existing_count.actual_quantity_g,
      v_baseline
    );
  ELSE
    SELECT prior.actual_quantity_g
    INTO v_baseline
    FROM public.inventory_physical_counts prior
    WHERE prior.restaurant_id = p_store_id
      AND prior.ingredient_id = p_ingredient_id
      AND prior.count_date < p_count_date
    ORDER BY prior.count_date DESC, prior.updated_at DESC
    LIMIT 1;

    v_baseline := COALESCE(v_baseline, v_item.current_stock, 0);
    v_event_before := v_baseline;
  END IF;

  v_variance := p_actual_quantity_g - v_baseline;
  v_event_change := p_actual_quantity_g - v_event_before;

  INSERT INTO public.inventory_physical_counts (
    restaurant_id,
    ingredient_id,
    count_date,
    actual_quantity_g,
    theoretical_quantity_g,
    variance_g,
    counted_by,
    note,
    updated_at
  )
  VALUES (
    p_store_id,
    p_ingredient_id,
    p_count_date,
    p_actual_quantity_g,
    v_baseline,
    v_variance,
    auth.uid(),
    v_note,
    now()
  )
  ON CONFLICT ON CONSTRAINT inventory_physical_counts_ingredient_id_count_date_key
  DO UPDATE SET
    actual_quantity_g = EXCLUDED.actual_quantity_g,
    variance_g = EXCLUDED.actual_quantity_g
      - COALESCE(
          public.inventory_physical_counts.theoretical_quantity_g,
          EXCLUDED.theoretical_quantity_g
        ),
    counted_by = EXCLUDED.counted_by,
    note = EXCLUDED.note,
    updated_at = now()
  RETURNING * INTO v_count_row;

  IF p_count_date = v_hcm_today THEN
    UPDATE public.inventory_items item
    SET current_stock = p_actual_quantity_g,
        updated_at = now()
    WHERE item.id = p_ingredient_id
      AND item.restaurant_id = p_store_id;
  END IF;

  INSERT INTO public.inventory_transactions (
    restaurant_id,
    ingredient_id,
    transaction_type,
    quantity_g,
    reference_type,
    reference_id,
    note,
    created_by,
    stock_before,
    stock_after,
    effective_date
  )
  VALUES (
    p_store_id,
    p_ingredient_id,
    'adjust',
    v_event_change,
    'physical_count',
    v_count_row.id,
    COALESCE(
      v_note,
      format('Daily inventory (%s)', to_char(p_count_date, 'YYYY-MM-DD'))
    ),
    auth.uid(),
    v_event_before,
    p_actual_quantity_g,
    p_count_date
  )
  RETURNING * INTO v_transaction;

  INSERT INTO public.audit_logs (
    actor_id,
    action,
    entity_type,
    entity_id,
    details
  )
  VALUES (
    auth.uid(),
    'inventory_daily_stock_saved',
    'inventory_physical_counts',
    v_count_row.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'ingredient_id', p_ingredient_id,
      'count_date', p_count_date,
      'stock_before', v_event_before,
      'stock_after', p_actual_quantity_g,
      'daily_baseline', v_baseline,
      'daily_variance', v_count_row.variance_g,
      'note', v_note,
      'current_stock_updated', p_count_date = v_hcm_today
    )
  );

  RETURN QUERY
  SELECT
    p_ingredient_id,
    p_count_date,
    v_count_row.theoretical_quantity_g,
    v_count_row.actual_quantity_g,
    v_count_row.variance_g,
    v_transaction.id,
    v_count_row.updated_at;
END;
$$;

CREATE OR REPLACE FUNCTION public.save_photo_objet_daily_inventory_item(
  p_store_id uuid,
  p_item_id uuid DEFAULT NULL,
  p_name text DEFAULT NULL,
  p_current_stock numeric DEFAULT 0,
  p_count_date date DEFAULT
    ((now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date),
  p_note text DEFAULT NULL
) RETURNS public.inventory_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_item public.inventory_items%ROWTYPE;
  v_item_id uuid;
  v_name text := btrim(COALESCE(p_name, ''));
  v_current_stock numeric := COALESCE(p_current_stock, 0);
  v_action text;
BEGIN
  SELECT actor.*
  INTO v_actor
  FROM public.users actor
  WHERE actor.auth_id = auth.uid()
    AND actor.is_active = true
  LIMIT 1;

  IF NOT FOUND
     OR v_actor.role NOT IN (
       'photo_objet_master',
       'photo_objet_store_admin',
       'super_admin'
     ) THEN
    RAISE EXCEPTION 'PHOTO_INVENTORY_WRITE_FORBIDDEN';
  END IF;

  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'PHOTO_INVENTORY_STORE_REQUIRED';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) scope(store_id)
       WHERE scope.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'PHOTO_INVENTORY_STORE_FORBIDDEN';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.restaurants store
    WHERE store.id = p_store_id
      AND store.brand_id =
        '77000000-0000-0000-0000-000000000001'::uuid
      AND store.is_active = true
  ) THEN
    RAISE EXCEPTION 'PHOTO_INVENTORY_STORE_FORBIDDEN';
  END IF;

  IF v_name = '' THEN
    RAISE EXCEPTION 'PHOTO_INVENTORY_NAME_REQUIRED';
  END IF;

  IF v_current_stock < 0 THEN
    RAISE EXCEPTION 'PHOTO_INVENTORY_STOCK_INVALID';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.inventory_items item
    WHERE item.restaurant_id = p_store_id
      AND item.is_active = true
      AND lower(btrim(item.name)) = lower(v_name)
      AND (p_item_id IS NULL OR item.id <> p_item_id)
  ) THEN
    RAISE EXCEPTION 'PHOTO_INVENTORY_NAME_DUPLICATE';
  END IF;

  IF p_item_id IS NULL THEN
    INSERT INTO public.inventory_items (
      restaurant_id,
      name,
      quantity,
      unit,
      current_stock,
      updated_at
    )
    VALUES (
      p_store_id,
      v_name,
      0,
      'ea',
      0,
      now()
    )
    RETURNING * INTO v_item;
    v_item_id := v_item.id;
    v_action := 'photo_inventory_item_created';
  ELSE
    UPDATE public.inventory_items item
    SET name = v_name,
        updated_at = now()
    WHERE item.id = p_item_id
      AND item.restaurant_id = p_store_id
      AND item.is_active = true
    RETURNING item.* INTO v_item;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'PHOTO_INVENTORY_ITEM_NOT_FOUND';
    END IF;
    v_item_id := v_item.id;
    v_action := 'photo_inventory_item_updated';
  END IF;

  PERFORM public.apply_inventory_physical_count_line(
    p_store_id,
    p_count_date,
    v_item_id,
    v_current_stock,
    p_note
  );

  SELECT item.*
  INTO v_item
  FROM public.inventory_items item
  WHERE item.id = v_item_id;

  INSERT INTO public.audit_logs (
    actor_id,
    action,
    entity_type,
    entity_id,
    details
  )
  VALUES (
    auth.uid(),
    v_action,
    'inventory_items',
    v_item.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'name', v_item.name,
      'recorded_stock', v_current_stock,
      'recorded_date', p_count_date,
      'current_stock', v_item.current_stock,
      'unit', v_item.unit
    )
  );

  RETURN v_item;
END;
$$;

CREATE OR REPLACE FUNCTION public.upsert_photo_objet_inventory_item(
  p_store_id uuid,
  p_item_id uuid DEFAULT NULL,
  p_name text DEFAULT NULL,
  p_current_stock numeric DEFAULT 0
) RETURNS public.inventory_items
LANGUAGE sql
SECURITY INVOKER
SET search_path = public, auth, pg_catalog
AS $$
  SELECT public.save_photo_objet_daily_inventory_item(
    p_store_id,
    p_item_id,
    p_name,
    p_current_stock,
    (now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date,
    'Legacy current-stock save'
  );
$$;

CREATE OR REPLACE FUNCTION public.record_employee_inventory_adjustment(
  p_store_id uuid,
  p_employee_number text,
  p_ingredient_id uuid,
  p_transaction_type text,
  p_quantity_g numeric,
  p_note text DEFAULT NULL
) RETURNS public.inventory_transactions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_employee public.store_employees%ROWTYPE;
  v_item public.inventory_items%ROWTYPE;
  v_old_stock numeric;
  v_new_stock numeric;
  v_transaction_quantity numeric;
  v_transaction public.inventory_transactions%ROWTYPE;
BEGIN
  SELECT actor.*
  INTO v_actor
  FROM public.users actor
  WHERE actor.auth_id = auth.uid()
    AND actor.is_active = true
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN (
    'photo_objet_store_operator',
    'photo_objet_master',
    'photo_objet_store_admin',
    'store_admin',
    'brand_admin',
    'super_admin'
  ) OR (
    v_actor.role <> 'super_admin'
    AND NOT EXISTS (
      SELECT 1
      FROM public.user_accessible_stores(auth.uid()) scope(store_id)
      WHERE scope.store_id = p_store_id
    )
  ) THEN
    RAISE EXCEPTION 'EMPLOYEE_INVENTORY_FORBIDDEN';
  END IF;

  IF p_transaction_type NOT IN ('restock', 'adjust', 'waste')
     OR p_quantity_g IS NULL
     OR p_quantity_g <= 0 THEN
    RAISE EXCEPTION 'EMPLOYEE_INVENTORY_INPUT_INVALID';
  END IF;

  SELECT employee.*
  INTO v_employee
  FROM public.store_employees employee
  WHERE employee.store_id = p_store_id
    AND upper(employee.employee_number) =
      upper(btrim(p_employee_number))
    AND employee.is_active = true;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'EMPLOYEE_NUMBER_NOT_FOUND';
  END IF;

  SELECT item.*
  INTO v_item
  FROM public.inventory_items item
  WHERE item.id = p_ingredient_id
    AND item.restaurant_id = p_store_id
    AND item.is_active = true
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'EMPLOYEE_INVENTORY_ITEM_NOT_FOUND';
  END IF;

  v_old_stock := COALESCE(v_item.current_stock, 0);
  IF p_transaction_type = 'restock' THEN
    v_new_stock := v_old_stock + p_quantity_g;
    v_transaction_quantity := p_quantity_g;
  ELSIF p_transaction_type = 'waste' THEN
    v_new_stock := v_old_stock - p_quantity_g;
    v_transaction_quantity := -p_quantity_g;
  ELSE
    v_new_stock := p_quantity_g;
    v_transaction_quantity := p_quantity_g - v_old_stock;
  END IF;

  UPDATE public.inventory_items item
  SET current_stock = v_new_stock,
      updated_at = now()
  WHERE item.id = p_ingredient_id
    AND item.restaurant_id = p_store_id;

  INSERT INTO public.inventory_transactions (
    restaurant_id,
    ingredient_id,
    transaction_type,
    quantity_g,
    reference_type,
    note,
    created_by,
    performed_by_employee_id,
    stock_before,
    stock_after,
    effective_date
  )
  VALUES (
    p_store_id,
    p_ingredient_id,
    p_transaction_type,
    v_transaction_quantity,
    'employee_number',
    NULLIF(btrim(COALESCE(p_note, '')), ''),
    auth.uid(),
    v_employee.id,
    v_old_stock,
    v_new_stock,
    (now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date
  )
  RETURNING * INTO v_transaction;

  INSERT INTO public.audit_logs (
    actor_id,
    action,
    entity_type,
    entity_id,
    details
  )
  VALUES (
    auth.uid(),
    'employee_inventory_adjusted',
    'inventory_items',
    p_ingredient_id,
    jsonb_build_object(
      'store_id', p_store_id,
      'employee_id', v_employee.id,
      'employee_number', v_employee.employee_number,
      'transaction_type', p_transaction_type,
      'stock_before', v_old_stock,
      'stock_after', v_new_stock,
      'quantity_g', v_transaction_quantity
    )
  );

  RETURN v_transaction;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_inventory_stock_adjustment_history(
  p_store_id uuid,
  p_from date,
  p_to date,
  p_limit integer DEFAULT 200
) RETURNS TABLE (
  transaction_id uuid,
  ingredient_id uuid,
  ingredient_name text,
  ingredient_unit text,
  transaction_type text,
  quantity_change numeric(12,3),
  stock_before numeric(12,3),
  stock_after numeric(12,3),
  effective_date date,
  note text,
  recorded_at timestamptz,
  recorded_by_name text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
BEGIN
  SELECT actor.*
  INTO v_actor
  FROM public.users actor
  WHERE actor.auth_id = auth.uid()
    AND actor.is_active = true
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN (
    'admin',
    'store_admin',
    'brand_admin',
    'super_admin',
    'photo_objet_master',
    'photo_objet_store_admin'
  ) THEN
    RAISE EXCEPTION 'INVENTORY_HISTORY_FORBIDDEN';
  END IF;

  IF p_store_id IS NULL
     OR p_from IS NULL
     OR p_to IS NULL
     OR p_from > p_to
     OR p_limit NOT BETWEEN 1 AND 500 THEN
    RAISE EXCEPTION 'INVENTORY_HISTORY_QUERY_INVALID';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) scope(store_id)
       WHERE scope.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'INVENTORY_HISTORY_FORBIDDEN';
  END IF;

  RETURN QUERY
  SELECT
    transaction.id,
    transaction.ingredient_id,
    item.name,
    COALESCE(item.unit, 'ea'),
    transaction.transaction_type,
    transaction.quantity_g,
    transaction.stock_before,
    transaction.stock_after,
    COALESCE(
      transaction.effective_date,
      (transaction.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date
    ),
    transaction.note,
    transaction.created_at,
    COALESCE(
      NULLIF(btrim(employee.full_name), ''),
      NULLIF(btrim(employee.employee_number), ''),
      NULLIF(btrim(profile.full_name), ''),
      '-'
    )
  FROM public.inventory_transactions transaction
  JOIN public.inventory_items item
    ON item.id = transaction.ingredient_id
   AND item.restaurant_id = transaction.restaurant_id
  LEFT JOIN public.store_employees employee
    ON employee.id = transaction.performed_by_employee_id
  LEFT JOIN public.users profile
    ON profile.auth_id = transaction.created_by
  WHERE transaction.restaurant_id = p_store_id
    AND COALESCE(
      transaction.effective_date,
      (transaction.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date
    ) BETWEEN p_from AND p_to
  ORDER BY
    COALESCE(
      transaction.effective_date,
      (transaction.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date
    ) DESC,
    transaction.created_at DESC
  LIMIT p_limit;
END;
$$;

REVOKE ALL ON FUNCTION public.get_inventory_physical_count_sheet(
  uuid,
  date
) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.apply_inventory_physical_count_line(
  uuid,
  date,
  uuid,
  numeric,
  text
) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.save_photo_objet_daily_inventory_item(
  uuid,
  uuid,
  text,
  numeric,
  date,
  text
) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.upsert_photo_objet_inventory_item(
  uuid,
  uuid,
  text,
  numeric
) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.record_employee_inventory_adjustment(
  uuid,
  text,
  uuid,
  text,
  numeric,
  text
) FROM PUBLIC, anon, authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_inventory_stock_adjustment_history(
  uuid,
  date,
  date,
  integer
) FROM PUBLIC, anon, authenticated, service_role;

GRANT EXECUTE ON FUNCTION public.get_inventory_physical_count_sheet(
  uuid,
  date
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.apply_inventory_physical_count_line(
  uuid,
  date,
  uuid,
  numeric,
  text
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.save_photo_objet_daily_inventory_item(
  uuid,
  uuid,
  text,
  numeric,
  date,
  text
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.upsert_photo_objet_inventory_item(
  uuid,
  uuid,
  text,
  numeric
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_employee_inventory_adjustment(
  uuid,
  text,
  uuid,
  text,
  numeric,
  text
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_inventory_stock_adjustment_history(
  uuid,
  date,
  date,
  integer
) TO authenticated;

COMMENT ON COLUMN public.inventory_transactions.stock_before IS
  'Inventory quantity immediately before this adjustment when known.';
COMMENT ON COLUMN public.inventory_transactions.stock_after IS
  'Inventory quantity immediately after this adjustment when known.';
COMMENT ON COLUMN public.inventory_transactions.effective_date IS
  'HCM operating date to which this adjustment belongs.';
COMMENT ON FUNCTION public.save_photo_objet_daily_inventory_item(
  uuid,
  uuid,
  text,
  numeric,
  date,
  text
) IS
  'Creates or renames a Photo Objet inventory item and atomically saves its dated stock count.';
COMMENT ON FUNCTION public.upsert_photo_objet_inventory_item(
  uuid,
  uuid,
  text,
  numeric
) IS
  'Compatibility wrapper that routes legacy Photo Objet current-stock saves through the dated inventory ledger.';
COMMENT ON FUNCTION public.get_inventory_stock_adjustment_history(
  uuid,
  date,
  date,
  integer
) IS
  'Returns store-scoped inventory adjustment history with dated before/after quantities and a safe actor label.';

COMMIT;
