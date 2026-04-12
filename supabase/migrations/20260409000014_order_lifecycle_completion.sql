-- ============================================================
-- Bundle G-1: Order Lifecycle Completion
-- 2026-04-09
--
-- Purpose: Complete pre-payment order lifecycle with per-item
-- cancel, quantity edit, and table transfer.
--
-- Changes:
--   1. Extend order_items.status to include 'cancelled'
--   2. New RPC: cancel_order_item
--   3. New RPC: edit_order_item_quantity
--   4. New RPC: transfer_order_table
--   5. Update process_payment to exclude cancelled items
--   6. Update update_order_item_status to reject cancelled→* transitions
--
-- Invariants preserved:
--   - Payment immutability (no post-payment edits)
--   - Audit logging on all mutations
--   - Role-based access enforcement
--   - Tenant scoping via restaurant_id
--   - Table status consistency
--
-- Depends on: 20260409000013 (latest prior migration)
-- ============================================================

BEGIN;

-- ============================================================
-- STEP 1: Extend order_items.status CHECK to include 'cancelled'
-- ============================================================

ALTER TABLE order_items DROP CONSTRAINT IF EXISTS order_items_status_check;
ALTER TABLE order_items ADD CONSTRAINT order_items_status_check
  CHECK (status IN ('pending','preparing','ready','served','cancelled'));

-- ============================================================
-- STEP 2: cancel_order_item RPC
--
-- Cancels a single order item before it is served.
-- Allowed on: pending, preparing items only.
-- Roles: waiter, admin, super_admin.
-- ============================================================

CREATE OR REPLACE FUNCTION cancel_order_item(
  p_item_id UUID,
  p_restaurant_id UUID
) RETURNS order_items AS $$
DECLARE
  v_actor users%ROWTYPE;
  v_item order_items%ROWTYPE;
  v_order_status TEXT;
  v_from_status TEXT;
BEGIN
  -- Actor validation
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

  -- Lock item
  SELECT *
  INTO v_item
  FROM order_items
  WHERE id = p_item_id
    AND restaurant_id = p_restaurant_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_ITEM_NOT_FOUND';
  END IF;

  -- Check order is mutable
  SELECT status
  INTO v_order_status
  FROM orders
  WHERE id = v_item.order_id
  FOR UPDATE;

  IF v_order_status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'ORDER_NOT_MUTABLE';
  END IF;

  -- Only pending/preparing items can be cancelled
  IF v_item.status NOT IN ('pending', 'preparing') THEN
    RAISE EXCEPTION 'ITEM_NOT_CANCELLABLE';
  END IF;

  v_from_status := v_item.status;

  UPDATE order_items
  SET status = 'cancelled'
  WHERE id = p_item_id
  RETURNING * INTO v_item;

  -- Update order timestamp
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
      'restaurant_id', p_restaurant_id,
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

-- ============================================================
-- STEP 3: edit_order_item_quantity RPC
--
-- Edits quantity of a single pending order item.
-- Only pending items can be edited (kitchen has not started).
-- Roles: waiter, admin, super_admin.
-- ============================================================

CREATE OR REPLACE FUNCTION edit_order_item_quantity(
  p_item_id UUID,
  p_restaurant_id UUID,
  p_new_quantity INT
) RETURNS order_items AS $$
DECLARE
  v_actor users%ROWTYPE;
  v_item order_items%ROWTYPE;
  v_order_status TEXT;
  v_old_quantity INT;
BEGIN
  -- Actor validation
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

  -- Validate quantity
  IF p_new_quantity IS NULL OR p_new_quantity < 1 THEN
    RAISE EXCEPTION 'INVALID_QUANTITY';
  END IF;

  -- Lock item
  SELECT *
  INTO v_item
  FROM order_items
  WHERE id = p_item_id
    AND restaurant_id = p_restaurant_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_ITEM_NOT_FOUND';
  END IF;

  -- Check order is mutable
  SELECT status
  INTO v_order_status
  FROM orders
  WHERE id = v_item.order_id
  FOR UPDATE;

  IF v_order_status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'ORDER_NOT_MUTABLE';
  END IF;

  -- Only pending items can be quantity-edited
  IF v_item.status <> 'pending' THEN
    RAISE EXCEPTION 'ITEM_NOT_EDITABLE';
  END IF;

  v_old_quantity := v_item.quantity;

  -- No-op if same quantity
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
      'restaurant_id', p_restaurant_id,
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

-- ============================================================
-- STEP 4: transfer_order_table RPC
--
-- Moves an active order to a different available table.
-- Releases old table, occupies new table.
-- Roles: waiter, admin, super_admin.
-- ============================================================

CREATE OR REPLACE FUNCTION transfer_order_table(
  p_order_id UUID,
  p_restaurant_id UUID,
  p_new_table_id UUID
) RETURNS orders AS $$
DECLARE
  v_actor users%ROWTYPE;
  v_order orders%ROWTYPE;
  v_old_table_id UUID;
  v_new_table tables%ROWTYPE;
BEGIN
  -- Actor validation
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

  -- Lock order
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

  v_old_table_id := v_order.table_id;

  -- Cannot transfer to same table
  IF v_old_table_id = p_new_table_id THEN
    RAISE EXCEPTION 'TRANSFER_SAME_TABLE';
  END IF;

  -- Lock and validate new table
  SELECT *
  INTO v_new_table
  FROM tables
  WHERE id = p_new_table_id
    AND restaurant_id = p_restaurant_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'TABLE_NOT_FOUND';
  END IF;

  IF v_new_table.status <> 'available' THEN
    RAISE EXCEPTION 'TABLE_ALREADY_OCCUPIED';
  END IF;

  -- Move order to new table
  UPDATE orders
  SET table_id = p_new_table_id,
      updated_at = now()
  WHERE id = p_order_id
  RETURNING * INTO v_order;

  -- Occupy new table
  UPDATE tables
  SET status = 'occupied',
      updated_at = now()
  WHERE id = p_new_table_id;

  -- Release old table (if it had one)
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
      'restaurant_id', p_restaurant_id,
      'old_table_id', v_old_table_id,
      'new_table_id', p_new_table_id,
      'new_table_number', v_new_table.table_number
    )
  );

  RETURN v_order;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ============================================================
-- STEP 5: Update process_payment to exclude cancelled items
--
-- Critical: amount calculation and inventory deduction must skip
-- items with status = 'cancelled'.
-- ============================================================

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
  -- Actor validation
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

  -- Lock order
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

  -- Calculate expected amount EXCLUDING cancelled items
  SELECT COALESCE(SUM(unit_price * quantity), 0)
  INTO v_expected_amount
  FROM order_items
  WHERE order_id = p_order_id
    AND status <> 'cancelled';

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

  -- Inventory deduction EXCLUDING cancelled items
  FOR v_item IN
    SELECT oi.id AS order_item_id, oi.menu_item_id, oi.quantity AS ordered_qty
    FROM order_items oi
    WHERE oi.order_id = p_order_id
      AND oi.menu_item_id IS NOT NULL
      AND oi.status <> 'cancelled'
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

-- ============================================================
-- STEP 6: Update update_order_item_status
--
-- Add explicit guard: cancelled items cannot transition.
-- Transitions TO cancelled are already rejected by the
-- existing pair-based validation.
-- ============================================================

CREATE OR REPLACE FUNCTION update_order_item_status(
  p_item_id UUID,
  p_restaurant_id UUID,
  p_new_status TEXT
) RETURNS order_items AS $$
DECLARE
  v_actor users%ROWTYPE;
  v_item order_items%ROWTYPE;
  v_order_status TEXT;
  v_from_status TEXT;
BEGIN
  SELECT *
  INTO v_actor
  FROM users
  WHERE auth_id = auth.uid()
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('admin', 'super_admin', 'kitchen') THEN
    RAISE EXCEPTION 'ORDER_ITEM_STATUS_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin'
     AND v_actor.restaurant_id <> p_restaurant_id THEN
    RAISE EXCEPTION 'ORDER_ITEM_STATUS_FORBIDDEN';
  END IF;

  SELECT *
  INTO v_item
  FROM order_items
  WHERE id = p_item_id
    AND restaurant_id = p_restaurant_id
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

  -- Cancelled items are final — no further transitions
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
      'restaurant_id', p_restaurant_id,
      'from_status', v_from_status,
      'to_status', p_new_status
    )
  );

  RETURN v_item;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

COMMIT;
