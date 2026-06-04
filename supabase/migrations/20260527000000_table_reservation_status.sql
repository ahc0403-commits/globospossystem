BEGIN;

ALTER TABLE public.tables
  DROP CONSTRAINT IF EXISTS tables_status_check;

ALTER TABLE public.tables
  ADD CONSTRAINT tables_status_check
  CHECK (status IN ('available', 'reserved', 'occupied'));

DROP FUNCTION IF EXISTS public.admin_update_table(
  uuid,
  uuid,
  text,
  int,
  text,
  numeric,
  numeric,
  numeric,
  numeric,
  int,
  text,
  int
);

CREATE OR REPLACE FUNCTION public.admin_update_table(
  p_table_id UUID,
  p_store_id UUID,
  p_table_number TEXT DEFAULT NULL,
  p_seat_count INT DEFAULT NULL,
  p_status TEXT DEFAULT NULL,
  p_layout_x NUMERIC DEFAULT NULL,
  p_layout_y NUMERIC DEFAULT NULL,
  p_layout_w NUMERIC DEFAULT NULL,
  p_layout_h NUMERIC DEFAULT NULL,
  p_layout_rotation INT DEFAULT NULL,
  p_layout_shape TEXT DEFAULT NULL,
  p_layout_sort_order INT DEFAULT NULL
) RETURNS public.tables AS $$
DECLARE
  v_existing public.tables%ROWTYPE;
  v_updated public.tables%ROWTYPE;
  v_changed_fields TEXT[] := ARRAY[]::TEXT[];
  v_old_values JSONB := '{}'::JSONB;
  v_new_values JSONB := '{}'::JSONB;
  v_table_number TEXT := NULLIF(btrim(COALESCE(p_table_number, '')), '');
  v_layout_shape TEXT := NULLIF(btrim(COALESCE(p_layout_shape, '')), '');
BEGIN
  IF p_table_id IS NULL THEN
    RAISE EXCEPTION 'TABLE_ID_REQUIRED';
  END IF;

  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'TABLE_STORE_REQUIRED';
  END IF;

  IF p_status IS NOT NULL AND p_status NOT IN ('available', 'reserved', 'occupied') THEN
    RAISE EXCEPTION 'TABLE_STATUS_INVALID';
  END IF;

  SELECT *
  INTO v_existing
  FROM public.tables
  WHERE id = p_table_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TABLE_NOT_FOUND';
  END IF;

  IF v_existing.restaurant_id IS DISTINCT FROM p_store_id THEN
    RAISE EXCEPTION 'TABLE_STORE_MISMATCH';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(p_store_id);

  IF p_table_number IS NOT NULL THEN
    IF v_table_number IS NULL THEN
      RAISE EXCEPTION 'TABLE_NUMBER_REQUIRED';
    END IF;
    IF v_table_number IS DISTINCT FROM v_existing.table_number THEN
      v_changed_fields := array_append(v_changed_fields, 'table_number');
      v_old_values := v_old_values || jsonb_build_object('table_number', v_existing.table_number);
      v_new_values := v_new_values || jsonb_build_object('table_number', v_table_number);
    END IF;
  ELSE
    v_table_number := v_existing.table_number;
  END IF;

  IF p_seat_count IS NOT NULL AND p_seat_count IS DISTINCT FROM v_existing.seat_count THEN
    v_changed_fields := array_append(v_changed_fields, 'seat_count');
    v_old_values := v_old_values || jsonb_build_object('seat_count', v_existing.seat_count);
    v_new_values := v_new_values || jsonb_build_object('seat_count', p_seat_count);
  END IF;

  IF p_status IS NOT NULL AND p_status IS DISTINCT FROM v_existing.status THEN
    v_changed_fields := array_append(v_changed_fields, 'status');
    v_old_values := v_old_values || jsonb_build_object('status', v_existing.status);
    v_new_values := v_new_values || jsonb_build_object('status', p_status);
  END IF;

  IF p_layout_x IS NOT NULL AND p_layout_x IS DISTINCT FROM v_existing.layout_x THEN
    v_changed_fields := array_append(v_changed_fields, 'layout_x');
    v_old_values := v_old_values || jsonb_build_object('layout_x', v_existing.layout_x);
    v_new_values := v_new_values || jsonb_build_object('layout_x', p_layout_x);
  END IF;

  IF p_layout_y IS NOT NULL AND p_layout_y IS DISTINCT FROM v_existing.layout_y THEN
    v_changed_fields := array_append(v_changed_fields, 'layout_y');
    v_old_values := v_old_values || jsonb_build_object('layout_y', v_existing.layout_y);
    v_new_values := v_new_values || jsonb_build_object('layout_y', p_layout_y);
  END IF;

  IF p_layout_w IS NOT NULL AND p_layout_w IS DISTINCT FROM v_existing.layout_w THEN
    v_changed_fields := array_append(v_changed_fields, 'layout_w');
    v_old_values := v_old_values || jsonb_build_object('layout_w', v_existing.layout_w);
    v_new_values := v_new_values || jsonb_build_object('layout_w', p_layout_w);
  END IF;

  IF p_layout_h IS NOT NULL AND p_layout_h IS DISTINCT FROM v_existing.layout_h THEN
    v_changed_fields := array_append(v_changed_fields, 'layout_h');
    v_old_values := v_old_values || jsonb_build_object('layout_h', v_existing.layout_h);
    v_new_values := v_new_values || jsonb_build_object('layout_h', p_layout_h);
  END IF;

  IF p_layout_rotation IS NOT NULL AND p_layout_rotation IS DISTINCT FROM v_existing.layout_rotation THEN
    v_changed_fields := array_append(v_changed_fields, 'layout_rotation');
    v_old_values := v_old_values || jsonb_build_object('layout_rotation', v_existing.layout_rotation);
    v_new_values := v_new_values || jsonb_build_object('layout_rotation', p_layout_rotation);
  END IF;

  IF p_layout_shape IS NOT NULL THEN
    IF v_layout_shape NOT IN ('rectangle', 'round') THEN
      RAISE EXCEPTION 'TABLE_LAYOUT_SHAPE_INVALID';
    END IF;
    IF v_layout_shape IS DISTINCT FROM v_existing.layout_shape THEN
      v_changed_fields := array_append(v_changed_fields, 'layout_shape');
      v_old_values := v_old_values || jsonb_build_object('layout_shape', v_existing.layout_shape);
      v_new_values := v_new_values || jsonb_build_object('layout_shape', v_layout_shape);
    END IF;
  ELSE
    v_layout_shape := v_existing.layout_shape;
  END IF;

  IF p_layout_sort_order IS NOT NULL AND p_layout_sort_order IS DISTINCT FROM v_existing.layout_sort_order THEN
    v_changed_fields := array_append(v_changed_fields, 'layout_sort_order');
    v_old_values := v_old_values || jsonb_build_object('layout_sort_order', v_existing.layout_sort_order);
    v_new_values := v_new_values || jsonb_build_object('layout_sort_order', p_layout_sort_order);
  END IF;

  UPDATE public.tables
  SET table_number = v_table_number,
      seat_count = COALESCE(p_seat_count, v_existing.seat_count),
      status = COALESCE(p_status, v_existing.status),
      layout_x = COALESCE(p_layout_x, v_existing.layout_x),
      layout_y = COALESCE(p_layout_y, v_existing.layout_y),
      layout_w = COALESCE(p_layout_w, v_existing.layout_w),
      layout_h = COALESCE(p_layout_h, v_existing.layout_h),
      layout_rotation = COALESCE(p_layout_rotation, v_existing.layout_rotation),
      layout_shape = v_layout_shape,
      layout_sort_order = COALESCE(p_layout_sort_order, v_existing.layout_sort_order),
      updated_at = now()
  WHERE id = v_existing.id
  RETURNING * INTO v_updated;

  IF COALESCE(array_length(v_changed_fields, 1), 0) > 0 THEN
    INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
    VALUES (
      auth.uid(),
      'admin_update_table',
      'tables',
      v_updated.id,
      jsonb_build_object(
        'store_id', p_store_id,
        'changed_fields', to_jsonb(v_changed_fields),
        'old_values', v_old_values,
        'new_values', v_new_values,
        'updated_at_utc', now()
      )
    );
  END IF;

  RETURN v_updated;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.create_order(
  p_store_id uuid,
  p_table_id uuid,
  p_items jsonb
) RETURNS orders AS $$
DECLARE
  v_actor users%ROWTYPE;
  v_table tables%ROWTYPE;
  v_order orders%ROWTYPE;
  v_item_count int := 0;
BEGIN
  SELECT *
  INTO v_actor
  FROM users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('waiter', 'admin', 'store_admin', 'super_admin') THEN
    RAISE EXCEPTION 'ORDER_CREATE_FORBIDDEN';
  END IF;

  IF NOT is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'ORDER_CREATE_FORBIDDEN';
  END IF;

  IF jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'ORDER_ITEMS_REQUIRED';
  END IF;

  SELECT *
  INTO v_table
  FROM tables
  WHERE id = p_table_id
    AND restaurant_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TABLE_NOT_FOUND';
  END IF;

  IF v_table.status <> 'available' THEN
    RAISE EXCEPTION 'TABLE_NOT_AVAILABLE';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_items) item
    WHERE NULLIF(item->>'menu_item_id', '') IS NULL
       OR COALESCE((item->>'quantity')::int, 0) <= 0
  ) THEN
    RAISE EXCEPTION 'INVALID_ORDER_ITEM_INPUT';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_items) item
    LEFT JOIN menu_items m
      ON m.id = (item->>'menu_item_id')::uuid
     AND m.restaurant_id = p_store_id
     AND m.is_available = TRUE
    WHERE m.id IS NULL
  ) THEN
    RAISE EXCEPTION 'MENU_ITEM_NOT_AVAILABLE';
  END IF;

  INSERT INTO orders (restaurant_id, table_id, status, created_by)
  VALUES (p_store_id, p_table_id, 'pending', auth.uid())
  RETURNING * INTO v_order;

  INSERT INTO order_items (
    order_id,
    menu_item_id,
    quantity,
    unit_price,
    label,
    display_name,
    restaurant_id,
    item_type
  )
  SELECT
    v_order.id,
    m.id,
    (item->>'quantity')::int,
    m.price,
    m.name,
    m.name,
    p_store_id,
    'menu_item'
  FROM jsonb_array_elements(p_items) item
  JOIN menu_items m
    ON m.id = (item->>'menu_item_id')::uuid
   AND m.restaurant_id = p_store_id
   AND m.is_available = TRUE;

  GET DIAGNOSTICS v_item_count = ROW_COUNT;

  UPDATE tables
  SET status = 'occupied',
      updated_at = now()
  WHERE id = p_table_id;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'create_order',
    'orders',
    v_order.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'table_id', p_table_id,
      'item_count', v_item_count,
      'sales_channel', 'dine_in'
    )
  );

  RETURN v_order;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.create_buffet_order(
  p_store_id uuid,
  p_table_id uuid,
  p_guest_count int,
  p_extra_items jsonb DEFAULT '[]'
) RETURNS orders AS $$
DECLARE
  v_actor users%ROWTYPE;
  v_table tables%ROWTYPE;
  v_operation_mode text;
  v_per_person_charge decimal(12,2);
  v_order orders%ROWTYPE;
  v_extra_item_count int := 0;
  v_buffet_pretax decimal(15,2);
  v_buffet_vat decimal(15,2);
  v_buffet_total decimal(15,2);
BEGIN
  SELECT *
  INTO v_actor
  FROM users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('waiter', 'admin', 'store_admin', 'super_admin') THEN
    RAISE EXCEPTION 'ORDER_CREATE_FORBIDDEN';
  END IF;

  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'ORDER_STORE_REQUIRED';
  END IF;

  IF NOT is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'ORDER_CREATE_FORBIDDEN';
  END IF;

  SELECT *
  INTO v_table
  FROM tables
  WHERE id = p_table_id
    AND restaurant_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TABLE_NOT_FOUND';
  END IF;

  IF v_table.status <> 'available' THEN
    RAISE EXCEPTION 'TABLE_NOT_AVAILABLE';
  END IF;

  SELECT operation_mode, per_person_charge
  INTO v_operation_mode, v_per_person_charge
  FROM restaurants
  WHERE id = p_store_id;

  IF v_operation_mode NOT IN ('buffet', 'hybrid') THEN
    RAISE EXCEPTION 'OPERATION_MODE_MISMATCH';
  END IF;

  IF p_guest_count IS NULL OR p_guest_count < 1 THEN
    RAISE EXCEPTION 'BUFFET_GUEST_COUNT_REQUIRED';
  END IF;

  IF jsonb_typeof(p_extra_items) <> 'array' THEN
    RAISE EXCEPTION 'INVALID_ORDER_ITEM_INPUT';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_extra_items) item
    WHERE NULLIF(item->>'menu_item_id', '') IS NULL
       OR COALESCE((item->>'quantity')::int, 0) <= 0
  ) THEN
    RAISE EXCEPTION 'INVALID_ORDER_ITEM_INPUT';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_extra_items) item
    LEFT JOIN menu_items m
      ON m.id = (item->>'menu_item_id')::uuid
     AND m.restaurant_id = p_store_id
     AND m.is_available = TRUE
    WHERE m.id IS NULL
  ) THEN
    RAISE EXCEPTION 'MENU_ITEM_NOT_AVAILABLE';
  END IF;

  INSERT INTO orders (
    restaurant_id,
    table_id,
    status,
    created_by,
    guest_count
  )
  VALUES (p_store_id, p_table_id, 'pending', auth.uid(), p_guest_count)
  RETURNING * INTO v_order;

  v_buffet_pretax := ROUND(v_per_person_charge * p_guest_count, 2);
  v_buffet_vat := ROUND(v_buffet_pretax * 8 / 100, 2);
  v_buffet_total := v_buffet_pretax + v_buffet_vat;

  INSERT INTO order_items (
    order_id,
    restaurant_id,
    item_type,
    display_name,
    label,
    unit_price,
    quantity,
    status,
    vat_rate,
    vat_amount,
    total_amount_ex_tax,
    paying_amount_inc_tax
  )
  VALUES (
    v_order.id,
    p_store_id,
    'service_charge',
    'Buffet Base Charge',
    'Buffet Base Charge',
    v_per_person_charge,
    p_guest_count,
    'served',
    8,
    v_buffet_vat,
    v_buffet_pretax,
    v_buffet_total
  );

  IF jsonb_array_length(p_extra_items) > 0 THEN
    INSERT INTO order_items (
      order_id,
      menu_item_id,
      quantity,
      unit_price,
      label,
      display_name,
      restaurant_id,
      item_type
    )
    SELECT
      v_order.id,
      m.id,
      (item->>'quantity')::int,
      m.price,
      m.name,
      m.name,
      p_store_id,
      'menu_item'
    FROM jsonb_array_elements(p_extra_items) item
    JOIN menu_items m
      ON m.id = (item->>'menu_item_id')::uuid
     AND m.restaurant_id = p_store_id
     AND m.is_available = TRUE;

    GET DIAGNOSTICS v_extra_item_count = ROW_COUNT;
  END IF;

  UPDATE tables
  SET status = 'occupied',
      updated_at = now()
  WHERE id = p_table_id;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'create_buffet_order',
    'orders',
    v_order.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'table_id', p_table_id,
      'guest_count', p_guest_count,
      'extra_item_count', v_extra_item_count,
      'operation_mode', v_operation_mode,
      'buffet_base_total_ex_tax', v_buffet_pretax
    )
  );

  RETURN v_order;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

COMMIT;
