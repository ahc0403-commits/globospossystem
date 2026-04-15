-- ============================================================
-- Dine-in sales execution contract closure
-- 2026-04-09
-- Bounded scope:
-- - waiter/admin order creation and add-items
-- - cashier/admin payment completion
-- - waiter/admin order cancellation
-- - label snapshot correctness for kitchen/cashier visibility
-- - audit traceability for core sales actions
-- Out of scope:
-- - delivery
-- - settlement beyond dine-in payment completion
-- - attendance / inventory / qc domains
-- ============================================================

CREATE OR REPLACE FUNCTION create_order(
  p_restaurant_id UUID,
  p_table_id UUID,
  p_items JSONB
) RETURNS orders AS $$
DECLARE
  v_actor users%ROWTYPE;
  v_table tables%ROWTYPE;
  v_order orders%ROWTYPE;
  v_item_count INT := 0;
BEGIN
  SELECT *
  INTO v_actor
  FROM users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('waiter', 'admin', 'super_admin') THEN
    RAISE EXCEPTION 'ORDER_CREATE_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_restaurant_id THEN
    RAISE EXCEPTION 'ORDER_CREATE_FORBIDDEN';
  END IF;

  IF jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'ORDER_ITEMS_REQUIRED';
  END IF;

  SELECT *
  INTO v_table
  FROM tables
  WHERE id = p_table_id
    AND restaurant_id = p_restaurant_id
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
       OR COALESCE((item->>'quantity')::INT, 0) <= 0
  ) THEN
    RAISE EXCEPTION 'INVALID_ORDER_ITEM_INPUT';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_items) item
    LEFT JOIN menu_items m
      ON m.id = (item->>'menu_item_id')::UUID
     AND m.restaurant_id = p_restaurant_id
     AND m.is_available = TRUE
    WHERE m.id IS NULL
  ) THEN
    RAISE EXCEPTION 'MENU_ITEM_NOT_AVAILABLE';
  END IF;

  INSERT INTO orders (restaurant_id, table_id, status, created_by)
  VALUES (p_restaurant_id, p_table_id, 'pending', auth.uid())
  RETURNING * INTO v_order;

  INSERT INTO order_items (
    order_id,
    menu_item_id,
    quantity,
    unit_price,
    label,
    restaurant_id,
    item_type
  )
  SELECT
    v_order.id,
    m.id,
    (item->>'quantity')::INT,
    m.price,
    m.name,
    p_restaurant_id,
    'standard'
  FROM jsonb_array_elements(p_items) item
  JOIN menu_items m
    ON m.id = (item->>'menu_item_id')::UUID
   AND m.restaurant_id = p_restaurant_id
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
      'restaurant_id', p_restaurant_id,
      'table_id', p_table_id,
      'item_count', v_item_count,
      'sales_channel', 'dine_in'
    )
  );

  RETURN v_order;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;
CREATE OR REPLACE FUNCTION create_buffet_order(
  p_restaurant_id UUID,
  p_table_id UUID,
  p_guest_count INT,
  p_extra_items JSONB DEFAULT '[]'
) RETURNS orders AS $$
DECLARE
  v_actor users%ROWTYPE;
  v_table tables%ROWTYPE;
  v_operation_mode TEXT;
  v_per_person_charge DECIMAL(12,2);
  v_order orders%ROWTYPE;
  v_extra_item_count INT := 0;
BEGIN
  SELECT *
  INTO v_actor
  FROM users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('waiter', 'admin', 'super_admin') THEN
    RAISE EXCEPTION 'ORDER_CREATE_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_restaurant_id THEN
    RAISE EXCEPTION 'ORDER_CREATE_FORBIDDEN';
  END IF;

  SELECT *
  INTO v_table
  FROM tables
  WHERE id = p_table_id
    AND restaurant_id = p_restaurant_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TABLE_NOT_FOUND';
  END IF;

  IF v_table.status = 'occupied' THEN
    RAISE EXCEPTION 'TABLE_ALREADY_OCCUPIED';
  END IF;

  SELECT operation_mode, per_person_charge
  INTO v_operation_mode, v_per_person_charge
  FROM restaurants
  WHERE id = p_restaurant_id;

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
       OR COALESCE((item->>'quantity')::INT, 0) <= 0
  ) THEN
    RAISE EXCEPTION 'INVALID_ORDER_ITEM_INPUT';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_extra_items) item
    LEFT JOIN menu_items m
      ON m.id = (item->>'menu_item_id')::UUID
     AND m.restaurant_id = p_restaurant_id
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
  VALUES (p_restaurant_id, p_table_id, 'pending', auth.uid(), p_guest_count)
  RETURNING * INTO v_order;

  INSERT INTO order_items (
    order_id,
    restaurant_id,
    item_type,
    label,
    unit_price,
    quantity,
    status
  )
  VALUES (
    v_order.id,
    p_restaurant_id,
    'buffet_base',
    '1인 고정 요금',
    v_per_person_charge,
    p_guest_count,
    'served'
  );

  IF jsonb_array_length(p_extra_items) > 0 THEN
    INSERT INTO order_items (
      order_id,
      menu_item_id,
      quantity,
      unit_price,
      label,
      restaurant_id,
      item_type
    )
    SELECT
      v_order.id,
      m.id,
      (item->>'quantity')::INT,
      m.price,
      m.name,
      p_restaurant_id,
      'a_la_carte'
    FROM jsonb_array_elements(p_extra_items) item
    JOIN menu_items m
      ON m.id = (item->>'menu_item_id')::UUID
     AND m.restaurant_id = p_restaurant_id
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
      'restaurant_id', p_restaurant_id,
      'table_id', p_table_id,
      'guest_count', p_guest_count,
      'extra_item_count', v_extra_item_count,
      'operation_mode', v_operation_mode
    )
  );

  RETURN v_order;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;
CREATE OR REPLACE FUNCTION add_items_to_order(
  p_order_id UUID,
  p_restaurant_id UUID,
  p_items JSONB
) RETURNS SETOF order_items AS $$
DECLARE
  v_actor users%ROWTYPE;
  v_order orders%ROWTYPE;
  v_inserted_count INT := 0;
BEGIN
  SELECT *
  INTO v_actor
  FROM users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('waiter', 'admin', 'super_admin') THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_restaurant_id THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  IF jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'ORDER_ITEMS_REQUIRED';
  END IF;

  SELECT *
  INTO v_order
  FROM orders
  WHERE id = p_order_id
    AND restaurant_id = p_restaurant_id
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
       OR COALESCE((item->>'quantity')::INT, 0) <= 0
  ) THEN
    RAISE EXCEPTION 'INVALID_ORDER_ITEM_INPUT';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_items) item
    LEFT JOIN menu_items m
      ON m.id = (item->>'menu_item_id')::UUID
     AND m.restaurant_id = p_restaurant_id
     AND m.is_available = TRUE
    WHERE m.id IS NULL
  ) THEN
    RAISE EXCEPTION 'MENU_ITEM_NOT_AVAILABLE';
  END IF;

  RETURN QUERY
  INSERT INTO order_items (
    order_id,
    menu_item_id,
    quantity,
    unit_price,
    label,
    restaurant_id,
    item_type
  )
  SELECT
    p_order_id,
    m.id,
    (item->>'quantity')::INT,
    m.price,
    m.name,
    p_restaurant_id,
    'standard'
  FROM jsonb_array_elements(p_items) item
  JOIN menu_items m
    ON m.id = (item->>'menu_item_id')::UUID
   AND m.restaurant_id = p_restaurant_id
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
      'restaurant_id', p_restaurant_id,
      'added_item_count', v_inserted_count
    )
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;
CREATE OR REPLACE FUNCTION process_payment(
  p_order_id UUID,
  p_restaurant_id UUID,
  p_amount DECIMAL(12,2),
  p_method TEXT
) RETURNS payments AS $$
DECLARE
  v_actor users%ROWTYPE;
  v_order orders%ROWTYPE;
  v_payment payments%ROWTYPE;
  v_table_id UUID;
  v_is_revenue BOOLEAN;
  v_item RECORD;
  v_recipe RECORD;
  v_deduct_qty DECIMAL(12,3);
  v_expected_amount DECIMAL(12,2);
BEGIN
  SELECT *
  INTO v_actor
  FROM users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('cashier', 'admin', 'super_admin') THEN
    RAISE EXCEPTION 'PAYMENT_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_restaurant_id THEN
    RAISE EXCEPTION 'PAYMENT_FORBIDDEN';
  END IF;

  IF p_method NOT IN ('cash', 'card', 'pay', 'service') THEN
    RAISE EXCEPTION 'INVALID_PAYMENT_METHOD';
  END IF;

  SELECT *
  INTO v_order
  FROM orders
  WHERE id = p_order_id
    AND restaurant_id = p_restaurant_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  IF v_order.status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'ORDER_NOT_PAYABLE';
  END IF;

  IF EXISTS (SELECT 1 FROM payments WHERE order_id = p_order_id) THEN
    RAISE EXCEPTION 'PAYMENT_ALREADY_EXISTS';
  END IF;

  SELECT COALESCE(SUM(unit_price * quantity), 0)
  INTO v_expected_amount
  FROM order_items
  WHERE order_id = p_order_id;

  IF v_expected_amount <= 0 THEN
    RAISE EXCEPTION 'ORDER_TOTAL_INVALID';
  END IF;

  IF ROUND(COALESCE(p_amount, 0)::numeric, 2) <> ROUND(v_expected_amount, 2) THEN
    RAISE EXCEPTION 'PAYMENT_AMOUNT_MISMATCH';
  END IF;

  v_is_revenue := (p_method <> 'service');

  INSERT INTO payments (
    order_id,
    restaurant_id,
    amount,
    method,
    processed_by,
    is_revenue
  )
  VALUES (
    p_order_id,
    p_restaurant_id,
    p_amount,
    p_method,
    auth.uid(),
    v_is_revenue
  )
  RETURNING * INTO v_payment;

  UPDATE orders
  SET status = 'completed',
      updated_at = now()
  WHERE id = p_order_id
  RETURNING table_id INTO v_table_id;

  IF v_table_id IS NOT NULL THEN
    UPDATE tables
    SET status = 'available',
        updated_at = now()
    WHERE id = v_table_id;
  END IF;

  FOR v_item IN
    SELECT oi.id AS order_item_id, oi.menu_item_id, oi.quantity AS ordered_qty
    FROM order_items oi
    WHERE oi.order_id = p_order_id
      AND oi.menu_item_id IS NOT NULL
  LOOP
    FOR v_recipe IN
      SELECT mr.ingredient_id, mr.quantity_g
      FROM menu_recipes mr
      WHERE mr.menu_item_id = v_item.menu_item_id
        AND mr.restaurant_id = p_restaurant_id
    LOOP
      v_deduct_qty := v_item.ordered_qty * v_recipe.quantity_g;
      UPDATE inventory_items
      SET current_stock = current_stock - v_deduct_qty,
          updated_at = now()
      WHERE id = v_recipe.ingredient_id
        AND restaurant_id = p_restaurant_id;

      INSERT INTO inventory_transactions (
        restaurant_id,
        ingredient_id,
        transaction_type,
        quantity_g,
        reference_type,
        reference_id,
        created_by
      )
      VALUES (
        p_restaurant_id,
        v_recipe.ingredient_id,
        'deduct',
        -v_deduct_qty,
        'order_item',
        v_item.order_item_id,
        auth.uid()
      );
    END LOOP;
  END LOOP;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'process_payment',
    'payments',
    v_payment.id,
    jsonb_build_object(
      'restaurant_id', p_restaurant_id,
      'order_id', p_order_id,
      'amount', p_amount,
      'method', p_method,
      'is_revenue', v_is_revenue
    )
  );

  RETURN v_payment;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;
CREATE OR REPLACE FUNCTION cancel_order(
  p_order_id UUID,
  p_restaurant_id UUID
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

  IF NOT FOUND OR v_actor.role NOT IN ('waiter', 'admin', 'super_admin') THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_restaurant_id THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  SELECT *
  INTO v_order
  FROM orders
  WHERE id = p_order_id
    AND restaurant_id = p_restaurant_id
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
      'restaurant_id', p_restaurant_id,
      'from_status', 'pending_or_confirmed',
      'to_status', 'cancelled'
    )
  );

  RETURN v_order;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;
