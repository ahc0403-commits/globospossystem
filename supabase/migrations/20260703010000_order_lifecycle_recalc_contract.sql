-- 20260703010000_order_lifecycle_recalc_contract.sql
-- Implements ORDER_LIFECYCLE_STATE_CONTRACT_2026_07_03.md (harness C1, C2,
-- H2, H3). Single derivation function recalc_order_status becomes the only
-- place order status is computed from item states; cancel_order cascades to
-- items before releasing the table; process_payment rejects orders whose
-- active items are not all ready|served.
--
-- Verified by supabase/tests/order_lifecycle_contract_test.sql (Gate 2).

BEGIN;

-- ============================================================
-- 1. recalc_order_status — single source of order status derivation.
--    Terminal states (completed/cancelled) are never derived away;
--    completed is set only by process_payment, cancelled by cancel_order
--    or by this function when every item has been cancelled.
-- ============================================================
CREATE OR REPLACE FUNCTION public.recalc_order_status(
  p_order_id uuid
) RETURNS void AS $$
DECLARE
  v_order orders%ROWTYPE;
  v_active int;
  v_done int;
  v_started int;
  v_next text;
BEGIN
  SELECT *
  INTO v_order
  FROM orders
  WHERE id = p_order_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  IF v_order.status IN ('completed', 'cancelled') THEN
    RETURN;
  END IF;

  SELECT
    count(*) FILTER (WHERE status <> 'cancelled'),
    count(*) FILTER (WHERE status IN ('ready', 'served')),
    count(*) FILTER (WHERE status IN ('preparing', 'ready', 'served'))
  INTO v_active, v_done, v_started
  FROM order_items
  WHERE order_id = p_order_id;

  IF v_active = 0 THEN
    v_next := 'cancelled';
  ELSIF v_done = v_active THEN
    v_next := 'serving';
  ELSIF v_started > 0 THEN
    v_next := 'confirmed';
  ELSE
    v_next := 'pending';
  END IF;

  IF v_next = v_order.status THEN
    UPDATE orders SET updated_at = now() WHERE id = p_order_id;
    RETURN;
  END IF;

  UPDATE orders
  SET status = v_next,
      updated_at = now()
  WHERE id = p_order_id;

  -- All items cancelled ⇒ the order dies; release its table unless another
  -- live order occupies it (contract invariant I5).
  IF v_next = 'cancelled' AND v_order.table_id IS NOT NULL THEN
    UPDATE tables
    SET status = 'available',
        updated_at = now()
    WHERE id = v_order.table_id
      AND NOT EXISTS (
        SELECT 1
        FROM orders o
        WHERE o.table_id = v_order.table_id
          AND o.id <> p_order_id
          AND o.status IN ('pending', 'confirmed', 'serving')
      );
  END IF;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'recalc_order_status',
    'orders',
    p_order_id,
    jsonb_build_object(
      'from_status', v_order.status,
      'to_status', v_next
    )
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- Existing production RPCs may still use the legacy p_restaurant_id argument
-- names. PostgreSQL cannot change argument names with CREATE OR REPLACE, so
-- recreate these same-identity RPCs inside this transaction before defining
-- the store-named contracts below.
DROP FUNCTION IF EXISTS public.cancel_order(uuid, uuid);
DROP FUNCTION IF EXISTS public.cancel_order_item(uuid, uuid);
DROP FUNCTION IF EXISTS public.add_items_to_order(uuid, uuid, jsonb);
DROP FUNCTION IF EXISTS public.update_order_item_status(uuid, uuid, text);
DROP FUNCTION IF EXISTS public.process_payment(uuid, uuid, numeric, text);

-- ============================================================
-- 2. cancel_order — cancel unfinished items BEFORE releasing the table
--    (harness C2). Orders with served items are not cancellable through
--    this path (spec: refund/void domain). serving orders stay blocked
--    (pilot decision 2026-07-03: keep current guard).
-- ============================================================
CREATE OR REPLACE FUNCTION public.cancel_order(
  p_order_id uuid,
  p_store_id uuid
) RETURNS orders AS $$
DECLARE
  v_actor users%ROWTYPE;
  v_order orders%ROWTYPE;
  v_from_status text;
  v_cancelled_items int := 0;
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

  IF EXISTS (
    SELECT 1
    FROM order_items
    WHERE order_id = p_order_id
      AND status = 'served'
  ) THEN
    RAISE EXCEPTION 'ORDER_HAS_SERVED_ITEMS';
  END IF;

  v_from_status := v_order.status;

  -- Cascade: no item may remain in kitchen for a dead order (invariant I4).
  UPDATE order_items
  SET status = 'cancelled'
  WHERE order_id = p_order_id
    AND status IN ('pending', 'preparing', 'ready');
  GET DIAGNOSTICS v_cancelled_items = ROW_COUNT;

  UPDATE orders
  SET status = 'cancelled',
      updated_at = now()
  WHERE id = p_order_id
  RETURNING * INTO v_order;

  -- Table release only after the item cascade, and only if no other live
  -- order occupies the table (invariant I5).
  IF v_order.table_id IS NOT NULL THEN
    UPDATE tables
    SET status = 'available',
        updated_at = now()
    WHERE id = v_order.table_id
      AND NOT EXISTS (
        SELECT 1
        FROM orders o
        WHERE o.table_id = v_order.table_id
          AND o.id <> p_order_id
          AND o.status IN ('pending', 'confirmed', 'serving')
      );
  END IF;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'cancel_order',
    'orders',
    p_order_id,
    jsonb_build_object(
      'store_id', p_store_id,
      'from_status', v_from_status,
      'to_status', 'cancelled',
      'cancelled_item_count', v_cancelled_items
    )
  );

  RETURN v_order;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ============================================================
-- 3. cancel_order_item — 'ready' items become cancellable (harness H2;
--    served stays terminal), and the order status is recalculated so the
--    last cancelled item auto-cancels the order and frees the table.
-- ============================================================
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

  IF v_item.status NOT IN ('pending', 'preparing', 'ready') THEN
    RAISE EXCEPTION 'ITEM_NOT_CANCELLABLE';
  END IF;

  v_from_status := v_item.status;

  UPDATE order_items
  SET status = 'cancelled'
  WHERE id = p_item_id
  RETURNING * INTO v_item;

  PERFORM public.recalc_order_status(v_item.order_id);

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

-- ============================================================
-- 4. add_items_to_order — recalculate order status after insert
--    (harness C1: a serving order gains a pending item and must demote
--    to confirmed so the cashier queue reflects reality).
-- ============================================================
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

  PERFORM public.recalc_order_status(p_order_id);

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

-- ============================================================
-- 5. update_order_item_status — the inline partial derivation
--    (20260703000000:75-100) is replaced by recalc_order_status.
-- ============================================================
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

  PERFORM public.recalc_order_status(v_item.order_id);

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'update_order_item_status',
    'order_items',
    p_item_id,
    jsonb_build_object(
      'store_id', p_store_id,
      'order_id', v_item.order_id,
      'from_status', v_from_status,
      'to_status', p_new_status,
      'order_status_after', (SELECT status FROM orders WHERE id = v_item.order_id)
    )
  );

  RETURN v_item;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

-- ============================================================
-- 6. process_payment — identical to 20260428000002 except the payability
--    guard (inserted below the terminal-status check). See section marker
--    "Contract invariant I3".
-- ============================================================
CREATE OR REPLACE FUNCTION public.process_payment(
  p_order_id uuid,
  p_store_id uuid,
  p_amount numeric,
  p_method text
)
RETURNS payments
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_actor                  users%ROWTYPE;
  v_order                  orders%ROWTYPE;
  v_payment                payments%ROWTYPE;
  v_brand                  brands%ROWTYPE;
  v_table_id               uuid;
  v_item                   RECORD;
  v_recipe                 RECORD;
  v_deduct_qty             decimal(12,3);
  v_food_subtotal          decimal(15,2) := 0;
  v_alcohol_subtotal       decimal(15,2) := 0;
  v_sc_rate                decimal(5,2)  := 0;
  v_sc_pretax              decimal(15,2);
  v_sc_vat                 decimal(15,2);
  v_sc_total               decimal(15,2);
  v_ref_id                 text;
  v_tax_entity_id          uuid;
  v_einvoice_shop_id       uuid;
  v_send_payload           jsonb;
  v_products               jsonb := '[]'::jsonb;
  v_pretax                 decimal(15,2);
  v_vat_rate               decimal(5,2);
  v_vat_amt                decimal(15,2);
  v_total_inc              decimal(15,2);
  v_is_revenue             boolean := true;
  v_payment_method_storage text := p_method;
  v_order_total            decimal(15,2) := 0;
  v_total_paid_before      decimal(15,2) := 0;
  v_total_paid_after       decimal(15,2) := 0;
  v_should_complete        boolean := false;
  v_vat_pricing_mode       text := 'exclusive';
  v_line_gross             decimal(15,2);
BEGIN
  SELECT * INTO v_actor
  FROM users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('cashier','admin','store_admin','brand_admin','super_admin') THEN
    RAISE EXCEPTION 'PAYMENT_FORBIDDEN';
  END IF;

  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'PAYMENT_STORE_REQUIRED';
  END IF;

  IF NOT is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'PAYMENT_FORBIDDEN';
  END IF;

  IF p_method = 'SERVICE' THEN
    v_is_revenue := FALSE;
    v_payment_method_storage := 'OTHER';
  ELSIF p_method NOT IN (
    'CASH','CREDITCARD','ATM','MOMO','ZALOPAY',
    'VNPAY','SHOPEEPAY','BANKTRANSFER','VOUCHER','CREDITSALE','OTHER'
  ) THEN
    RAISE EXCEPTION 'INVALID_PAYMENT_METHOD';
  END IF;

  SELECT * INTO v_order
  FROM orders
  WHERE id = p_order_id
    AND restaurant_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  IF v_order.status IN ('completed','cancelled') THEN
    RAISE EXCEPTION 'ORDER_NOT_PAYABLE';
  END IF;

  -- Contract invariant I3 (ORDER_LIFECYCLE_STATE_CONTRACT_2026_07_03):
  -- an order is payable only when every active item is ready or served.
  IF EXISTS (
    SELECT 1
    FROM order_items oi
    WHERE oi.order_id = p_order_id
      AND oi.status NOT IN ('ready', 'served', 'cancelled')
  ) THEN
    RAISE EXCEPTION 'ORDER_NOT_PAYABLE';
  END IF;

  IF p_amount <= 0 THEN
    RAISE EXCEPTION 'PAYMENT_AMOUNT_INVALID';
  END IF;

  SELECT b.* INTO v_brand
  FROM restaurants r
  JOIN brands b ON b.id = r.brand_id
  WHERE r.id = p_store_id;

  SELECT COALESCE(r.vat_pricing_mode, 'exclusive')
  INTO v_vat_pricing_mode
  FROM restaurants r
  WHERE r.id = p_store_id;

  IF FOUND AND v_brand.service_charge_enabled THEN
    v_sc_rate := COALESCE(v_brand.service_charge_rate, 0);
  END IF;

  FOR v_item IN
    SELECT
      oi.id,
      oi.unit_price,
      oi.quantity,
      oi.display_name,
      oi.label,
      COALESCE(mi.vat_category, 'food') AS vat_category
    FROM order_items oi
    LEFT JOIN menu_items mi ON mi.id = oi.menu_item_id
    WHERE oi.order_id = p_order_id
      AND oi.status <> 'cancelled'
      AND oi.item_type = 'menu_item'
  LOOP
    v_line_gross := ROUND(v_item.unit_price * v_item.quantity, 2);
    v_vat_rate := CASE v_item.vat_category WHEN 'alcohol' THEN 10 ELSE 8 END;
    IF v_vat_pricing_mode = 'inclusive' THEN
      v_total_inc := v_line_gross;
      v_pretax := ROUND(v_line_gross / (1 + (v_vat_rate / 100)), 2);
      v_vat_amt := v_line_gross - v_pretax;
    ELSE
      v_pretax := v_line_gross;
      v_vat_amt := ROUND(v_pretax * v_vat_rate / 100, 2);
      v_total_inc := v_pretax + v_vat_amt;
    END IF;

    UPDATE order_items
    SET
      vat_rate = v_vat_rate,
      vat_amount = v_vat_amt,
      total_amount_ex_tax = v_pretax,
      paying_amount_inc_tax = v_total_inc
    WHERE id = v_item.id;

    IF v_item.vat_category = 'alcohol' THEN
      v_alcohol_subtotal := v_alcohol_subtotal + v_pretax;
    ELSE
      v_food_subtotal := v_food_subtotal + v_pretax;
    END IF;

    v_products := v_products || jsonb_build_object(
      'item_name', COALESCE(NULLIF(v_item.display_name, ''), v_item.label, 'Item'),
      'unit_price', v_item.unit_price::text,
      'quantity', v_item.quantity::text,
      'uom', 'EA',
      'total_amount', v_pretax::text,
      'vat_rate', (v_vat_rate::int::text || '%'),
      'vat_amount', v_vat_amt::text,
      'paying_amount', v_total_inc::text
    );
  END LOOP;

  IF v_sc_rate > 0 AND v_food_subtotal > 0 THEN
    v_sc_pretax := ROUND(v_food_subtotal * v_sc_rate / 100, 2);
    v_sc_vat := ROUND(v_sc_pretax * 8 / 100, 2);
    v_sc_total := v_sc_pretax + v_sc_vat;

    IF NOT EXISTS (
      SELECT 1 FROM order_items
      WHERE order_id = p_order_id
        AND item_type = 'service_charge'
        AND display_name = 'Service Charge (Food)'
    ) THEN
      INSERT INTO order_items (
        order_id, restaurant_id, item_type, display_name, menu_item_id,
        unit_price, quantity, label, status, vat_rate, vat_amount,
        total_amount_ex_tax, paying_amount_inc_tax
      )
      VALUES (
        p_order_id, p_store_id, 'service_charge', 'Service Charge (Food)', NULL,
        v_sc_pretax, 1, 'Service Charge (Food)', 'served', 8, v_sc_vat,
        v_sc_pretax, v_sc_total
      );
    END IF;

    v_products := v_products || jsonb_build_object(
      'item_name', 'Service Charge (Food)',
      'unit_price', v_sc_pretax::text,
      'quantity', '1',
      'uom', 'EA',
      'total_amount', v_sc_pretax::text,
      'vat_rate', '8%',
      'vat_amount', v_sc_vat::text,
      'paying_amount', v_sc_total::text
    );
  END IF;

  IF v_sc_rate > 0 AND v_alcohol_subtotal > 0 THEN
    v_sc_pretax := ROUND(v_alcohol_subtotal * v_sc_rate / 100, 2);
    v_sc_vat := ROUND(v_sc_pretax * 10 / 100, 2);
    v_sc_total := v_sc_pretax + v_sc_vat;

    IF NOT EXISTS (
      SELECT 1 FROM order_items
      WHERE order_id = p_order_id
        AND item_type = 'service_charge'
        AND display_name = 'Service Charge (Alcohol)'
    ) THEN
      INSERT INTO order_items (
        order_id, restaurant_id, item_type, display_name, menu_item_id,
        unit_price, quantity, label, status, vat_rate, vat_amount,
        total_amount_ex_tax, paying_amount_inc_tax
      )
      VALUES (
        p_order_id, p_store_id, 'service_charge', 'Service Charge (Alcohol)', NULL,
        v_sc_pretax, 1, 'Service Charge (Alcohol)', 'served', 10, v_sc_vat,
        v_sc_pretax, v_sc_total
      );
    END IF;

    v_products := v_products || jsonb_build_object(
      'item_name', 'Service Charge (Alcohol)',
      'unit_price', v_sc_pretax::text,
      'quantity', '1',
      'uom', 'EA',
      'total_amount', v_sc_pretax::text,
      'vat_rate', '10%',
      'vat_amount', v_sc_vat::text,
      'paying_amount', v_sc_total::text
    );
  END IF;

  SELECT ROUND(COALESCE(SUM(COALESCE(paying_amount_inc_tax, unit_price * quantity)), 0), 2)
  INTO v_order_total
  FROM order_items
  WHERE order_id = p_order_id
    AND status <> 'cancelled';

  IF v_order_total <= 0 THEN
    RAISE EXCEPTION 'ORDER_TOTAL_INVALID';
  END IF;

  SELECT COALESCE(SUM(amount_portion), 0)
  INTO v_total_paid_before
  FROM payments
  WHERE order_id = p_order_id;

  IF v_total_paid_before + p_amount > v_order_total + 0.01 THEN
    RAISE EXCEPTION 'PAYMENT_AMOUNT_EXCEEDS_REMAINING';
  END IF;

  v_total_paid_after := ROUND(v_total_paid_before + p_amount, 2);
  v_should_complete := v_total_paid_after >= v_order_total - 0.01;

  INSERT INTO payments (
    order_id,
    restaurant_id,
    amount,
    method,
    processed_by,
    is_revenue,
    amount_portion
  )
  VALUES (
    p_order_id,
    p_store_id,
    p_amount,
    v_payment_method_storage,
    auth.uid(),
    v_is_revenue,
    p_amount
  )
  RETURNING * INTO v_payment;

  IF v_should_complete THEN
    UPDATE orders
    SET status = 'completed', updated_at = now()
    WHERE id = p_order_id
    RETURNING table_id INTO v_table_id;

    IF v_table_id IS NOT NULL THEN
      UPDATE tables
      SET status = 'available', updated_at = now()
      WHERE id = v_table_id;
    END IF;

    FOR v_item IN
      SELECT
        oi.id AS order_item_id,
        oi.menu_item_id,
        oi.quantity AS ordered_qty
      FROM order_items oi
      WHERE oi.order_id = p_order_id
        AND oi.menu_item_id IS NOT NULL
        AND oi.status <> 'cancelled'
        AND oi.item_type = 'menu_item'
    LOOP
      FOR v_recipe IN
        SELECT mr.ingredient_id, mr.quantity_g
        FROM menu_recipes mr
        WHERE mr.menu_item_id = v_item.menu_item_id
          AND mr.restaurant_id = p_store_id
      LOOP
        v_deduct_qty := v_item.ordered_qty * v_recipe.quantity_g;

        UPDATE inventory_items
        SET current_stock = current_stock - v_deduct_qty, updated_at = now()
        WHERE id = v_recipe.ingredient_id
          AND restaurant_id = p_store_id;

        INSERT INTO inventory_transactions (
          restaurant_id, ingredient_id, transaction_type,
          quantity_g, reference_type, reference_id, created_by
        )
        VALUES (
          p_store_id, v_recipe.ingredient_id, 'deduct',
          -v_deduct_qty, 'order_item', v_item.order_item_id, auth.uid()
        );
      END LOOP;
    END LOOP;

    IF v_is_revenue THEN
      SELECT r.tax_entity_id
      INTO v_tax_entity_id
      FROM restaurants r
      WHERE r.id = p_store_id;

      IF v_tax_entity_id IS NOT NULL
         AND NOT EXISTS (
           SELECT 1
           FROM tax_entity
           WHERE id = v_tax_entity_id
             AND tax_code = 'PLACEHOLDER_DEV_000'
         ) THEN
        SELECT id
        INTO v_einvoice_shop_id
        FROM einvoice_shop
        WHERE tax_entity_id = v_tax_entity_id
          AND EXISTS (
            SELECT 1
            FROM jsonb_array_elements(COALESCE(templates, '[]'::jsonb)) AS t
            WHERE t->>'status_code' = '1'
          )
        LIMIT 1;

        IF v_einvoice_shop_id IS NOT NULL THEN
          v_ref_id := generate_uuidv7();

          SELECT jsonb_build_object(
            'ref_id', v_ref_id,
            'store_code', COALESCE(es.provider_shop_code, te.tax_code),
            'store_name', COALESCE(es.shop_name, r.name),
            'cqt_code', '',
            'bill_no', v_ref_id,
            'pos_no', '001',
            'order_date', to_char(now() AT TIME ZONE 'Asia/Ho_Chi_Minh', 'YYYYMMDDHH24MISS'),
            'order_id', v_ref_id,
            'trans_type', 1,
            'payment_method', v_payment_method_storage,
            'products', v_products
          )
          INTO v_send_payload
          FROM restaurants r
          JOIN tax_entity te ON te.id = v_tax_entity_id
          JOIN einvoice_shop es ON es.id = v_einvoice_shop_id
          WHERE r.id = p_store_id;

          INSERT INTO einvoice_jobs (
            ref_id, order_id, tax_entity_id, einvoice_shop_id,
            redinvoice_requested, status, send_order_payload
          )
          VALUES (
            v_ref_id, p_order_id, v_tax_entity_id, v_einvoice_shop_id,
            FALSE, 'pending', v_send_payload
          );
        END IF;
      END IF;
    END IF;
  END IF;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'process_payment',
    'payments',
    v_payment.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'order_id', p_order_id,
      'amount', p_amount,
      'input_method', p_method,
      'stored_method', v_payment_method_storage,
      'is_revenue', v_is_revenue,
      'order_total', v_order_total,
      'total_paid_before', v_total_paid_before,
      'total_paid_after', v_total_paid_after,
      'payment_completes_order', v_should_complete,
      'ref_id', v_ref_id,
      'einvoice_job_created', v_ref_id IS NOT NULL
    )
  );

  RETURN v_payment;
END;
$$;

-- ============================================================
-- 7. One-time backfill: re-derive every live order so orders stuck
--    invisible (mixed pending+ready) surface correctly.
-- ============================================================
SELECT public.recalc_order_status(o.id)
FROM orders o
WHERE o.status NOT IN ('completed', 'cancelled');

COMMIT;
