-- Phase 2 Step 5 — RPC enum fixes (companion to Step 5 schema migration)
-- Fixes add_items_to_order and process_payment to align with new DB constraints:
--   order_items.item_type CHECK ('menu_item','service_charge')
--   order_items.display_name NOT NULL
--   payments.method CHECK (WeTax enum)
--   payments.amount_portion NOT NULL

-- ===========================================================================
-- 1. add_items_to_order — 'standard' → 'menu_item', add display_name
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.add_items_to_order(p_order_id uuid, p_restaurant_id uuid, p_items jsonb)
 RETURNS SETOF order_items
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_actor users%ROWTYPE;
  v_order orders%ROWTYPE;
  v_inserted_count INT := 0;
BEGIN
  SELECT * INTO v_actor FROM users
  WHERE auth_id = auth.uid() AND is_active = TRUE LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('waiter', 'admin', 'super_admin') THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin' AND v_actor.restaurant_id <> p_restaurant_id THEN
    RAISE EXCEPTION 'ORDER_MUTATION_FORBIDDEN';
  END IF;

  IF jsonb_typeof(p_items) <> 'array' OR jsonb_array_length(p_items) = 0 THEN
    RAISE EXCEPTION 'ORDER_ITEMS_REQUIRED';
  END IF;

  SELECT * INTO v_order FROM orders
  WHERE id = p_order_id AND restaurant_id = p_restaurant_id FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_NOT_FOUND'; END IF;
  IF v_order.status IN ('completed', 'cancelled') THEN RAISE EXCEPTION 'ORDER_NOT_MUTABLE'; END IF;

  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_items) item
    WHERE NULLIF(item->>'menu_item_id', '') IS NULL
       OR COALESCE((item->>'quantity')::INT, 0) <= 0
  ) THEN RAISE EXCEPTION 'INVALID_ORDER_ITEM_INPUT'; END IF;

  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_items) item
    LEFT JOIN menu_items m
      ON m.id = (item->>'menu_item_id')::UUID
     AND m.restaurant_id = p_restaurant_id
     AND m.is_available = TRUE
    WHERE m.id IS NULL
  ) THEN RAISE EXCEPTION 'MENU_ITEM_NOT_AVAILABLE'; END IF;

  RETURN QUERY
  INSERT INTO order_items (
    order_id, menu_item_id, quantity, unit_price,
    label, restaurant_id, item_type, display_name
  )
  SELECT
    p_order_id, m.id, (item->>'quantity')::INT, m.price,
    m.name, p_restaurant_id, 'menu_item', m.name
  FROM jsonb_array_elements(p_items) item
  JOIN menu_items m
    ON m.id = (item->>'menu_item_id')::UUID
   AND m.restaurant_id = p_restaurant_id
   AND m.is_available = TRUE
  RETURNING *;

  GET DIAGNOSTICS v_inserted_count = ROW_COUNT;

  UPDATE orders SET updated_at = now() WHERE id = p_order_id;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(), 'add_items_to_order', 'orders', p_order_id,
    jsonb_build_object('restaurant_id', p_restaurant_id, 'added_item_count', v_inserted_count)
  );
END;
$function$;

-- ===========================================================================
-- 2. process_payment — WeTax method enum, is_revenue=TRUE, amount_portion
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.process_payment(p_order_id uuid, p_restaurant_id uuid, p_amount numeric, p_method text)
 RETURNS payments
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
DECLARE
  v_actor        users%ROWTYPE;
  v_order        orders%ROWTYPE;
  v_payment      payments%ROWTYPE;
  v_table_id     UUID;
  v_is_revenue   BOOLEAN;
  v_item         RECORD;
  v_recipe       RECORD;
  v_deduct_qty   DECIMAL(12,3);
  v_expected_amount DECIMAL(12,2);
BEGIN
  SELECT * INTO v_actor FROM users
  WHERE auth_id = auth.uid() AND is_active = TRUE LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('cashier', 'admin', 'super_admin') THEN
    RAISE EXCEPTION 'PAYMENT_FORBIDDEN';
  END IF;

  IF v_actor.role <> 'super_admin' AND v_actor.restaurant_id <> p_restaurant_id THEN
    RAISE EXCEPTION 'PAYMENT_FORBIDDEN';
  END IF;

  -- WeTax sendOrderInfo enum validation
  IF p_method NOT IN (
    'CASH','CREDITCARD','ATM','MOMO','ZALOPAY',
    'VNPAY','SHOPEEPAY','BANKTRANSFER','VOUCHER','CREDITSALE','OTHER'
  ) THEN
    RAISE EXCEPTION 'INVALID_PAYMENT_METHOD';
  END IF;

  SELECT * INTO v_order FROM orders
  WHERE id = p_order_id AND restaurant_id = p_restaurant_id FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_NOT_FOUND'; END IF;
  IF v_order.status IN ('completed', 'cancelled') THEN RAISE EXCEPTION 'ORDER_NOT_PAYABLE'; END IF;
  IF EXISTS (SELECT 1 FROM payments WHERE order_id = p_order_id) THEN
    RAISE EXCEPTION 'PAYMENT_ALREADY_EXISTS';
  END IF;

  SELECT COALESCE(SUM(unit_price * quantity), 0) INTO v_expected_amount
  FROM order_items WHERE order_id = p_order_id AND status <> 'cancelled';

  IF v_expected_amount <= 0 THEN RAISE EXCEPTION 'ORDER_TOTAL_INVALID'; END IF;

  IF ROUND(COALESCE(p_amount, 0)::numeric, 2) <> ROUND(v_expected_amount, 2) THEN
    RAISE EXCEPTION 'PAYMENT_AMOUNT_MISMATCH';
  END IF;

  -- All WeTax payment methods are revenue; service charge is now an order_item line
  v_is_revenue := TRUE;

  INSERT INTO payments (
    order_id, restaurant_id, amount, method,
    processed_by, is_revenue, amount_portion
  )
  VALUES (
    p_order_id, p_restaurant_id, p_amount, p_method,
    auth.uid(), v_is_revenue, p_amount
  )
  RETURNING * INTO v_payment;

  UPDATE orders SET status = 'completed', updated_at = now()
  WHERE id = p_order_id RETURNING table_id INTO v_table_id;

  IF v_table_id IS NOT NULL THEN
    UPDATE tables SET status = 'available', updated_at = now() WHERE id = v_table_id;
  END IF;

  -- Inventory deduction
  FOR v_item IN
    SELECT oi.id AS order_item_id, oi.menu_item_id, oi.quantity AS ordered_qty
    FROM order_items oi
    WHERE oi.order_id = p_order_id AND oi.menu_item_id IS NOT NULL AND oi.status <> 'cancelled'
  LOOP
    FOR v_recipe IN
      SELECT mr.ingredient_id, mr.quantity_g FROM menu_recipes mr
      WHERE mr.menu_item_id = v_item.menu_item_id AND mr.restaurant_id = p_restaurant_id
    LOOP
      v_deduct_qty := v_item.ordered_qty * v_recipe.quantity_g;
      UPDATE inventory_items
      SET current_stock = current_stock - v_deduct_qty, updated_at = now()
      WHERE id = v_recipe.ingredient_id AND restaurant_id = p_restaurant_id;

      INSERT INTO inventory_transactions (
        restaurant_id, ingredient_id, transaction_type,
        quantity_g, reference_type, reference_id, created_by
      ) VALUES (
        p_restaurant_id, v_recipe.ingredient_id, 'deduct',
        -v_deduct_qty, 'order_item', v_item.order_item_id, auth.uid()
      );
    END LOOP;
  END LOOP;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(), 'process_payment', 'payments', v_payment.id,
    jsonb_build_object(
      'restaurant_id', p_restaurant_id, 'order_id', p_order_id,
      'amount', p_amount, 'method', p_method, 'is_revenue', v_is_revenue
    )
  );

  RETURN v_payment;
END;
$function$;;
