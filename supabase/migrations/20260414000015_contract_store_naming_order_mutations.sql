BEGIN;

DROP FUNCTION IF EXISTS public.create_order(uuid, uuid, jsonb);
DROP FUNCTION IF EXISTS public.add_items_to_order(uuid, uuid, jsonb);
DROP FUNCTION IF EXISTS public.cancel_order(uuid, uuid);
DROP FUNCTION IF EXISTS public.cancel_order_item(uuid, uuid);
DROP FUNCTION IF EXISTS public.edit_order_item_quantity(uuid, uuid, int);
DROP FUNCTION IF EXISTS public.transfer_order_table(uuid, uuid, uuid);
DROP FUNCTION IF EXISTS public.update_order_item_status(uuid, uuid, text);

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

  IF v_table.status = 'occupied' THEN
    RAISE EXCEPTION 'TABLE_ALREADY_OCCUPIED';
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

CREATE OR REPLACE FUNCTION public.add_items_to_order(
  p_order_id uuid,
  p_store_id uuid,
  p_items jsonb
) RETURNS SETOF order_items AS $$
DECLARE
  v_actor users%ROWTYPE;
  v_order orders%ROWTYPE;
  v_inserted_count int := 0;
BEGIN
  SELECT *
  INTO v_actor
  FROM users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('waiter', 'admin', 'store_admin', 'super_admin') THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  IF NOT is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  IF jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'ORDER_ITEMS_REQUIRED';
  END IF;

  SELECT *
  INTO v_order
  FROM orders
  WHERE id = p_order_id
    AND restaurant_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  IF v_order.status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'ORDER_NOT_MUTABLE';
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

  RETURN QUERY
  INSERT INTO order_items (
    order_id, menu_item_id, quantity, unit_price,
    label, display_name, restaurant_id, item_type
  )
  SELECT
    p_order_id, m.id, (item->>'quantity')::int, m.price,
    m.name, m.name, p_store_id, 'menu_item'
  FROM jsonb_array_elements(p_items) item
  JOIN menu_items m
    ON m.id = (item->>'menu_item_id')::uuid
   AND m.restaurant_id = p_store_id
   AND m.is_available = TRUE
  RETURNING *;

  GET DIAGNOSTICS v_inserted_count = ROW_COUNT;

  UPDATE orders
  SET updated_at = now()
  WHERE id = p_order_id;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'add_items_to_order',
    'orders',
    p_order_id,
    jsonb_build_object(
      'store_id', p_store_id,
      'added_item_count', v_inserted_count
    )
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.cancel_order(
  p_order_id uuid,
  p_store_id uuid
) RETURNS orders AS $$
DECLARE
  v_actor users%ROWTYPE;
  v_order orders%ROWTYPE;
BEGIN
  SELECT *
  INTO v_actor
  FROM users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('waiter', 'admin', 'store_admin', 'super_admin') THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  IF NOT is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  SELECT *
  INTO v_order
  FROM orders
  WHERE id = p_order_id
    AND restaurant_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  IF v_order.status NOT IN ('pending', 'confirmed') THEN
    RAISE EXCEPTION 'ORDER_NOT_CANCELLABLE';
  END IF;

  UPDATE orders
  SET status = 'cancelled',
      updated_at = now()
  WHERE id = p_order_id
  RETURNING * INTO v_order;

  IF v_order.table_id IS NOT NULL THEN
    UPDATE tables
    SET status = 'available',
        updated_at = now()
    WHERE id = v_order.table_id;
  END IF;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'cancel_order',
    'orders',
    p_order_id,
    jsonb_build_object(
      'store_id', p_store_id,
      'from_status', 'pending_or_confirmed',
      'to_status', 'cancelled'
    )
  );

  RETURN v_order;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.cancel_order_item(
  p_item_id uuid,
  p_store_id uuid
) RETURNS order_items AS $$
DECLARE
  v_actor users%ROWTYPE;
  v_item order_items%ROWTYPE;
  v_order_status text;
  v_from_status text;
BEGIN
  SELECT *
  INTO v_actor
  FROM users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('waiter', 'admin', 'store_admin', 'super_admin') THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  IF NOT is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  SELECT *
  INTO v_item
  FROM order_items
  WHERE id = p_item_id
    AND restaurant_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_ITEM_NOT_FOUND';
  END IF;

  SELECT status
  INTO v_order_status
  FROM orders
  WHERE id = v_item.order_id
  FOR UPDATE;

  IF v_order_status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'ORDER_NOT_MUTABLE';
  END IF;

  IF v_item.status NOT IN ('pending', 'preparing') THEN
    RAISE EXCEPTION 'ITEM_NOT_CANCELLABLE';
  END IF;

  v_from_status := v_item.status;

  UPDATE order_items
  SET status = 'cancelled'
  WHERE id = p_item_id
  RETURNING * INTO v_item;

  UPDATE orders
  SET updated_at = now()
  WHERE id = v_item.order_id;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'cancel_order_item',
    'order_items',
    p_item_id,
    jsonb_build_object(
      'store_id', p_store_id,
      'order_id', v_item.order_id,
      'from_status', v_from_status,
      'to_status', 'cancelled',
      'label', v_item.label,
      'quantity', v_item.quantity,
      'unit_price', v_item.unit_price
    )
  );

  RETURN v_item;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.edit_order_item_quantity(
  p_item_id uuid,
  p_store_id uuid,
  p_new_quantity int
) RETURNS order_items AS $$
DECLARE
  v_actor users%ROWTYPE;
  v_item order_items%ROWTYPE;
  v_order_status text;
  v_old_quantity int;
BEGIN
  SELECT *
  INTO v_actor
  FROM users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('waiter', 'admin', 'store_admin', 'super_admin') THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  IF NOT is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  IF p_new_quantity IS NULL OR p_new_quantity < 1 THEN
    RAISE EXCEPTION 'INVALID_QUANTITY';
  END IF;

  SELECT *
  INTO v_item
  FROM order_items
  WHERE id = p_item_id
    AND restaurant_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_ITEM_NOT_FOUND';
  END IF;

  SELECT status
  INTO v_order_status
  FROM orders
  WHERE id = v_item.order_id
  FOR UPDATE;

  IF v_order_status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'ORDER_NOT_MUTABLE';
  END IF;

  IF v_item.status <> 'pending' THEN
    RAISE EXCEPTION 'ITEM_NOT_EDITABLE';
  END IF;

  v_old_quantity := v_item.quantity;

  IF v_old_quantity = p_new_quantity THEN
    RETURN v_item;
  END IF;

  UPDATE order_items
  SET quantity = p_new_quantity
  WHERE id = p_item_id
  RETURNING * INTO v_item;

  UPDATE orders
  SET updated_at = now()
  WHERE id = v_item.order_id;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'edit_order_item_quantity',
    'order_items',
    p_item_id,
    jsonb_build_object(
      'store_id', p_store_id,
      'order_id', v_item.order_id,
      'label', v_item.label,
      'old_quantity', v_old_quantity,
      'new_quantity', p_new_quantity
    )
  );

  RETURN v_item;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.transfer_order_table(
  p_order_id uuid,
  p_store_id uuid,
  p_new_table_id uuid
) RETURNS orders AS $$
DECLARE
  v_actor users%ROWTYPE;
  v_order orders%ROWTYPE;
  v_old_table_id uuid;
  v_new_table tables%ROWTYPE;
BEGIN
  SELECT *
  INTO v_actor
  FROM users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('waiter', 'admin', 'store_admin', 'super_admin') THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  IF NOT is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  SELECT *
  INTO v_order
  FROM orders
  WHERE id = p_order_id
    AND restaurant_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  IF v_order.status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'ORDER_NOT_MUTABLE';
  END IF;

  v_old_table_id := v_order.table_id;

  IF v_old_table_id = p_new_table_id THEN
    RAISE EXCEPTION 'TRANSFER_SAME_TABLE';
  END IF;

  SELECT *
  INTO v_new_table
  FROM tables
  WHERE id = p_new_table_id
    AND restaurant_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TABLE_NOT_FOUND';
  END IF;

  IF v_new_table.status <> 'available' THEN
    RAISE EXCEPTION 'TABLE_ALREADY_OCCUPIED';
  END IF;

  UPDATE orders
  SET table_id = p_new_table_id,
      updated_at = now()
  WHERE id = p_order_id
  RETURNING * INTO v_order;

  UPDATE tables
  SET status = 'occupied',
      updated_at = now()
  WHERE id = p_new_table_id;

  IF v_old_table_id IS NOT NULL THEN
    UPDATE tables
    SET status = 'available',
        updated_at = now()
    WHERE id = v_old_table_id;
  END IF;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'transfer_order_table',
    'orders',
    p_order_id,
    jsonb_build_object(
      'store_id', p_store_id,
      'old_table_id', v_old_table_id,
      'new_table_id', p_new_table_id,
      'new_table_number', v_new_table.table_number
    )
  );

  RETURN v_order;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.update_order_item_status(
  p_item_id uuid,
  p_store_id uuid,
  p_new_status text
) RETURNS order_items AS $$
DECLARE
  v_actor users%ROWTYPE;
  v_item order_items%ROWTYPE;
  v_order_status text;
  v_from_status text;
BEGIN
  SELECT *
  INTO v_actor
  FROM users
  WHERE auth_id = auth.uid()
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'store_admin', 'super_admin', 'kitchen') THEN
    RAISE EXCEPTION 'ORDER_ITEM_STATUS_FORBIDDEN';
  END IF;

  IF NOT is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'ORDER_ITEM_STATUS_FORBIDDEN';
  END IF;

  SELECT *
  INTO v_item
  FROM order_items
  WHERE id = p_item_id
    AND restaurant_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_ITEM_NOT_FOUND';
  END IF;

  SELECT status
  INTO v_order_status
  FROM orders
  WHERE id = v_item.order_id
  FOR UPDATE;

  IF v_order_status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'ORDER_NOT_MUTABLE';
  END IF;

  IF v_item.status = 'cancelled' THEN
    RAISE EXCEPTION 'ITEM_IS_CANCELLED';
  END IF;

  IF NOT (
    (v_item.status = 'pending' AND p_new_status = 'preparing')
    OR (v_item.status = 'preparing' AND p_new_status = 'ready')
    OR (v_item.status = 'ready' AND p_new_status = 'served')
    OR v_item.status = p_new_status
  ) THEN
    RAISE EXCEPTION 'INVALID_ORDER_ITEM_STATUS_TRANSITION';
  END IF;

  v_from_status := v_item.status;

  UPDATE order_items
  SET status = p_new_status
  WHERE id = p_item_id
  RETURNING * INTO v_item;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'update_order_item_status',
    'order_items',
    p_item_id,
    jsonb_build_object(
      'store_id', p_store_id,
      'from_status', v_from_status,
      'to_status', p_new_status
    )
  );

  RETURN v_item;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

COMMIT;
