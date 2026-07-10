BEGIN;

ALTER TABLE public.payments
  DROP CONSTRAINT IF EXISTS payments_amount_check;

ALTER TABLE public.payments
  ADD CONSTRAINT payments_amount_check
  CHECK (amount >= 0);

ALTER TABLE public.payments
  DROP CONSTRAINT IF EXISTS payments_amount_portion_positive;

ALTER TABLE public.payments
  ADD CONSTRAINT payments_amount_portion_non_negative
  CHECK (amount_portion >= 0);

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
  v_discount               order_discounts%ROWTYPE;
  v_has_discount           boolean := false;
  v_table_id               uuid;
  v_item                   RECORD;
  v_recipe                 RECORD;
  v_deduct_qty             decimal(12,3);
  v_food_subtotal          decimal(15,2) := 0;
  v_alcohol_subtotal       decimal(15,2) := 0;
  v_menu_inc_total         decimal(15,2) := 0;
  v_menu_inc_cents         bigint := 0;
  v_sc_rate                decimal(5,2)  := 0;
  v_sc_pretax              decimal(15,2);
  v_sc_vat                 decimal(15,2);
  v_sc_total               decimal(15,2);
  v_pretax                 decimal(15,2);
  v_vat_rate               decimal(5,2);
  v_vat_amt                decimal(15,2);
  v_total_inc              decimal(15,2);
  v_is_revenue             boolean := true;
  v_payment_method_storage text := p_method;
  v_order_total            decimal(15,2) := 0;
  v_total_paid_before      decimal(15,2) := 0;
  v_total_paid_after       decimal(15,2) := 0;
  v_remaining_due          decimal(15,2) := 0;
  v_should_complete        boolean := false;
  v_vat_pricing_mode       text := 'exclusive';
  v_line_gross             decimal(15,2);
  v_discount_total         decimal(15,2) := 0;
  v_discount_cents         bigint := 0;
  v_remainder_cents        bigint := 0;
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

  IF COALESCE(v_order.order_purpose, 'customer') = 'staff_meal'
     AND p_method <> 'SERVICE' THEN
    RAISE EXCEPTION 'STAFF_MEAL_SERVICE_REQUIRED';
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

  IF p_amount < 0 THEN
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

  CREATE TEMP TABLE IF NOT EXISTS payment_discount_lines (
    line_id uuid PRIMARY KEY,
    menu_item_id uuid,
    unit_price numeric(12,2) NOT NULL,
    quantity integer NOT NULL,
    display_name text,
    label text,
    vat_category text NOT NULL,
    vat_rate numeric(5,2) NOT NULL,
    undiscounted_pretax numeric(15,2) NOT NULL,
    undiscounted_vat numeric(15,2) NOT NULL,
    undiscounted_inc numeric(15,2) NOT NULL,
    line_inc_cents bigint NOT NULL,
    base_discount_cents bigint NOT NULL DEFAULT 0,
    discount_fraction numeric NOT NULL DEFAULT 0,
    allocated_discount_cents bigint NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL
  ) ON COMMIT DROP;

  TRUNCATE TABLE payment_discount_lines;

  FOR v_item IN
    SELECT
      oi.id,
      oi.menu_item_id,
      oi.unit_price,
      oi.quantity,
      oi.display_name,
      oi.label,
      oi.created_at,
      COALESCE(mi.vat_category, 'food') AS vat_category
    FROM order_items oi
    LEFT JOIN menu_items mi ON mi.id = oi.menu_item_id
    WHERE oi.order_id = p_order_id
      AND oi.status <> 'cancelled'
      AND oi.item_type = 'menu_item'
    ORDER BY oi.created_at, oi.id
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

    INSERT INTO payment_discount_lines (
      line_id,
      menu_item_id,
      unit_price,
      quantity,
      display_name,
      label,
      vat_category,
      vat_rate,
      undiscounted_pretax,
      undiscounted_vat,
      undiscounted_inc,
      line_inc_cents,
      created_at
    )
    VALUES (
      v_item.id,
      v_item.menu_item_id,
      v_item.unit_price,
      v_item.quantity,
      v_item.display_name,
      v_item.label,
      v_item.vat_category,
      v_vat_rate,
      v_pretax,
      v_vat_amt,
      v_total_inc,
      ROUND(v_total_inc * 100)::bigint,
      v_item.created_at
    );

    v_menu_inc_total := v_menu_inc_total + v_total_inc;
    v_menu_inc_cents := v_menu_inc_cents + ROUND(v_total_inc * 100)::bigint;

    IF v_item.vat_category = 'alcohol' THEN
      v_alcohol_subtotal := v_alcohol_subtotal + v_pretax;
    ELSE
      v_food_subtotal := v_food_subtotal + v_pretax;
    END IF;
  END LOOP;

  SELECT *
  INTO v_discount
  FROM order_discounts
  WHERE order_id = p_order_id
    AND restaurant_id = p_store_id
    AND status = 'active'
  FOR UPDATE;

  IF FOUND THEN
    v_has_discount := true;
    IF v_menu_inc_total <= 0 THEN
      RAISE EXCEPTION 'ORDER_TOTAL_INVALID';
    END IF;

    IF v_discount.discount_mode = 'percent' THEN
      v_discount_total := ROUND(v_menu_inc_total * v_discount.discount_value / 100, 2);
    ELSE
      v_discount_total := LEAST(ROUND(v_discount.discount_value, 2), v_menu_inc_total);
    END IF;

    IF v_discount_total < 0 THEN
      RAISE EXCEPTION 'DISCOUNT_AMOUNT_INVALID';
    END IF;

    v_discount_cents := LEAST(ROUND(v_discount_total * 100)::bigint, v_menu_inc_cents);

    IF v_discount_cents > 0 AND v_menu_inc_cents > 0 THEN
      UPDATE payment_discount_lines
      SET base_discount_cents = FLOOR((v_discount_cents::numeric * line_inc_cents::numeric) / v_menu_inc_cents::numeric)::bigint,
          discount_fraction = ((v_discount_cents::numeric * line_inc_cents::numeric) / v_menu_inc_cents::numeric)
            - FLOOR((v_discount_cents::numeric * line_inc_cents::numeric) / v_menu_inc_cents::numeric);

      SELECT v_discount_cents - COALESCE(SUM(base_discount_cents), 0)
      INTO v_remainder_cents
      FROM payment_discount_lines;

      WITH ranked AS (
        SELECT
          line_id,
          row_number() OVER (ORDER BY discount_fraction DESC, line_id) AS rn
        FROM payment_discount_lines
      )
      UPDATE payment_discount_lines l
      SET allocated_discount_cents =
        l.base_discount_cents + CASE WHEN ranked.rn <= v_remainder_cents THEN 1 ELSE 0 END
      FROM ranked
      WHERE ranked.line_id = l.line_id;
    END IF;
  END IF;

  FOR v_item IN
    SELECT *
    FROM payment_discount_lines
    ORDER BY created_at, line_id
  LOOP
    v_total_inc := ROUND(GREATEST(v_item.line_inc_cents - v_item.allocated_discount_cents, 0)::numeric / 100, 2);
    v_vat_rate := v_item.vat_rate;
    v_pretax := ROUND(v_total_inc / (1 + (v_vat_rate / 100)), 2);
    v_vat_amt := v_total_inc - v_pretax;

    UPDATE order_items
    SET
      vat_rate = v_vat_rate,
      vat_amount = v_vat_amt,
      total_amount_ex_tax = v_pretax,
      paying_amount_inc_tax = v_total_inc
    WHERE id = v_item.line_id;

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
    ELSE
      UPDATE order_items
      SET unit_price = v_sc_pretax,
          quantity = 1,
          vat_rate = 8,
          vat_amount = v_sc_vat,
          total_amount_ex_tax = v_sc_pretax,
          paying_amount_inc_tax = v_sc_total,
          status = 'served'
      WHERE order_id = p_order_id
        AND item_type = 'service_charge'
        AND display_name = 'Service Charge (Food)';
    END IF;

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
    ELSE
      UPDATE order_items
      SET unit_price = v_sc_pretax,
          quantity = 1,
          vat_rate = 10,
          vat_amount = v_sc_vat,
          total_amount_ex_tax = v_sc_pretax,
          paying_amount_inc_tax = v_sc_total,
          status = 'served'
      WHERE order_id = p_order_id
        AND item_type = 'service_charge'
        AND display_name = 'Service Charge (Alcohol)';
    END IF;

  END IF;

  SELECT ROUND(COALESCE(SUM(COALESCE(paying_amount_inc_tax, unit_price * quantity)), 0), 2)
  INTO v_order_total
  FROM order_items
  WHERE order_id = p_order_id
    AND status <> 'cancelled';

  IF v_order_total < 0 OR (v_order_total <= 0 AND NOT v_has_discount) THEN
    RAISE EXCEPTION 'ORDER_TOTAL_INVALID';
  END IF;

  SELECT COALESCE(SUM(amount_portion), 0)
  INTO v_total_paid_before
  FROM payments
  WHERE order_id = p_order_id;

  v_remaining_due := ROUND(v_order_total - v_total_paid_before, 2);

  IF v_remaining_due < -0.01 THEN
    RAISE EXCEPTION 'PAYMENT_AMOUNT_EXCEEDS_REMAINING';
  END IF;

  IF GREATEST(v_remaining_due, 0) <= 0.01 THEN
    IF ABS(ROUND(COALESCE(p_amount, -1), 2)) > 0.01 THEN
      RAISE EXCEPTION 'PAYMENT_AMOUNT_EXCEEDS_REMAINING';
    END IF;
  ELSE
    IF ROUND(COALESCE(p_amount, -1), 2) <= 0 THEN
      RAISE EXCEPTION 'PAYMENT_AMOUNT_INVALID';
    END IF;

    IF ROUND(COALESCE(p_amount, -1), 2) - v_remaining_due > 0.01 THEN
      RAISE EXCEPTION 'PAYMENT_AMOUNT_EXCEEDS_REMAINING';
    END IF;
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

  IF v_has_discount AND v_should_complete THEN
    UPDATE order_discounts
    SET status = 'consumed',
        discount_amount = v_discount_cents::numeric / 100,
        updated_at = now()
    WHERE id = v_discount.id;
  END IF;

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
      'discount_id', CASE WHEN v_has_discount THEN v_discount.id ELSE NULL END,
      'discount_amount', v_discount_cents::numeric / 100,
      'total_paid_before', v_total_paid_before,
      'total_paid_after', v_total_paid_after,
      'payment_completes_order', v_should_complete
    )
  );

  RETURN v_payment;
END;
$$;

REVOKE ALL ON FUNCTION public.process_payment(uuid, uuid, numeric, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.process_payment(uuid, uuid, numeric, text) TO authenticated, service_role;

COMMIT;
