BEGIN;

-- Service Item Exclusion V1
-- A service item is real food/drink that was cooked and served, but excluded
-- from customer billing, revenue invoices, discount base, and service-charge
-- base. It is intentionally distinct from item_type='service_charge'.

ALTER TABLE public.order_items
  ADD COLUMN IF NOT EXISTS is_service_item boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS service_reason text,
  ADD COLUMN IF NOT EXISTS service_marked_by uuid REFERENCES auth.users(id),
  ADD COLUMN IF NOT EXISTS service_marked_at timestamptz;

COMMENT ON COLUMN public.order_items.is_service_item IS
  'True when a real menu item was provided as service/comp and excluded from customer billing. Distinct from item_type=service_charge.';
COMMENT ON COLUMN public.order_items.service_reason IS
  'Manager-approved reason for service-item billing exclusion.';

CREATE OR REPLACE FUNCTION public.calculate_order_discountable_total(
  p_order_id uuid,
  p_store_id uuid
) RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_vat_pricing_mode text := 'exclusive';
  v_item record;
  v_vat_rate numeric(5,2);
  v_line_gross numeric(15,2);
  v_line_inc numeric(15,2);
  v_total numeric(15,2) := 0;
BEGIN
  IF p_order_id IS NULL OR p_store_id IS NULL THEN
    RETURN 0;
  END IF;

  SELECT COALESCE(r.vat_pricing_mode, 'exclusive')
  INTO v_vat_pricing_mode
  FROM public.restaurants r
  WHERE r.id = p_store_id;

  FOR v_item IN
    SELECT
      oi.unit_price,
      oi.quantity,
      COALESCE(mi.vat_category, 'food') AS vat_category
    FROM public.order_items oi
    LEFT JOIN public.menu_items mi ON mi.id = oi.menu_item_id
    WHERE oi.order_id = p_order_id
      AND oi.restaurant_id = p_store_id
      AND oi.status <> 'cancelled'
      AND oi.item_type = 'menu_item'
      AND COALESCE(oi.is_service_item, false) = false
  LOOP
    v_line_gross := ROUND(v_item.unit_price * v_item.quantity, 2);
    v_vat_rate := CASE v_item.vat_category WHEN 'alcohol' THEN 10 ELSE 8 END;
    IF v_vat_pricing_mode = 'inclusive' THEN
      v_line_inc := v_line_gross;
    ELSE
      v_line_inc := v_line_gross + ROUND(v_line_gross * v_vat_rate / 100, 2);
    END IF;
    v_total := v_total + v_line_inc;
  END LOOP;

  RETURN ROUND(v_total, 2);
END;
$$;

REVOKE ALL ON FUNCTION public.calculate_order_discountable_total(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.calculate_order_discountable_total(uuid, uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.mark_order_item_service(
  p_item_id uuid,
  p_store_id uuid,
  p_reason text,
  p_manager_pin text
) RETURNS public.order_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_item public.order_items%ROWTYPE;
  v_order public.orders%ROWTYPE;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND
     OR v_actor.role NOT IN ('cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin')
     OR NOT (
       v_actor.role IN ('admin', 'store_admin', 'brand_admin', 'super_admin')
       OR COALESCE(v_actor.extra_permissions, ARRAY[]::text[]) @> ARRAY['discount_apply']
     ) THEN
    RAISE EXCEPTION 'SERVICE_MARK_FORBIDDEN';
  END IF;

  IF p_item_id IS NULL OR p_store_id IS NULL THEN
    RAISE EXCEPTION 'SERVICE_MARK_ITEM_REQUIRED';
  END IF;

  IF NULLIF(btrim(COALESCE(p_reason, '')), '') IS NULL THEN
    RAISE EXCEPTION 'SERVICE_REASON_REQUIRED';
  END IF;

  IF NOT public.is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'SERVICE_MARK_FORBIDDEN';
  END IF;

  PERFORM public.verify_discount_manager_pin_or_raise(p_store_id, p_manager_pin, 'mark_order_item_service');

  SELECT *
  INTO v_item
  FROM public.order_items
  WHERE id = p_item_id
    AND restaurant_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_ITEM_NOT_FOUND';
  END IF;

  IF v_item.item_type <> 'menu_item' THEN
    RAISE EXCEPTION 'SERVICE_MARK_ITEM_TYPE';
  END IF;

  IF v_item.status = 'cancelled' THEN
    RAISE EXCEPTION 'SERVICE_MARK_ITEM_CANCELLED';
  END IF;

  IF COALESCE(v_item.is_service_item, false) THEN
    RAISE EXCEPTION 'SERVICE_MARK_ALREADY';
  END IF;

  SELECT *
  INTO v_order
  FROM public.orders
  WHERE id = v_item.order_id
    AND restaurant_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  IF v_order.status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'ORDER_NOT_MUTABLE';
  END IF;

  IF COALESCE(v_order.order_purpose, 'customer') = 'staff_meal' THEN
    RAISE EXCEPTION 'SERVICE_MARK_PURPOSE_UNSUPPORTED';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.payments p
    WHERE p.order_id = v_order.id
  ) THEN
    RAISE EXCEPTION 'SERVICE_MARK_AFTER_PAYMENT';
  END IF;

  IF v_item.status NOT IN ('ready', 'served') THEN
    RAISE EXCEPTION 'SERVICE_MARK_ITEM_NOT_PROVIDED';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.order_items oi
    WHERE oi.order_id = v_order.id
      AND oi.restaurant_id = p_store_id
      AND oi.id <> p_item_id
      AND oi.status <> 'cancelled'
      AND oi.item_type = 'menu_item'
      AND COALESCE(oi.is_service_item, false) = false
  ) THEN
    RAISE EXCEPTION 'FULL_SERVICE_NOT_ALLOWED';
  END IF;

  UPDATE public.order_items
  SET is_service_item = true,
      service_reason = btrim(p_reason),
      service_marked_by = auth.uid(),
      service_marked_at = now(),
      vat_rate = 0,
      vat_amount = 0,
      total_amount_ex_tax = 0,
      paying_amount_inc_tax = 0
  WHERE id = v_item.id
  RETURNING * INTO v_item;

  PERFORM public.void_active_order_discount_for_item_change(
    v_order.id,
    p_store_id,
    'order_items_changed'
  );

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'mark_order_item_service',
    'order_items',
    v_item.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'order_id', v_order.id,
      'reason', btrim(p_reason),
      'label', COALESCE(v_item.display_name, v_item.label),
      'quantity', v_item.quantity,
      'unit_price', v_item.unit_price
    )
  );

  RETURN v_item;
END;
$$;

CREATE OR REPLACE FUNCTION public.unmark_order_item_service(
  p_item_id uuid,
  p_store_id uuid,
  p_reason text,
  p_manager_pin text
) RETURNS public.order_items
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_item public.order_items%ROWTYPE;
  v_order public.orders%ROWTYPE;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND
     OR v_actor.role NOT IN ('cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin')
     OR NOT (
       v_actor.role IN ('admin', 'store_admin', 'brand_admin', 'super_admin')
       OR COALESCE(v_actor.extra_permissions, ARRAY[]::text[]) @> ARRAY['discount_apply']
     ) THEN
    RAISE EXCEPTION 'SERVICE_MARK_FORBIDDEN';
  END IF;

  IF p_item_id IS NULL OR p_store_id IS NULL THEN
    RAISE EXCEPTION 'SERVICE_MARK_ITEM_REQUIRED';
  END IF;

  IF NULLIF(btrim(COALESCE(p_reason, '')), '') IS NULL THEN
    RAISE EXCEPTION 'SERVICE_REASON_REQUIRED';
  END IF;

  IF NOT public.is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'SERVICE_MARK_FORBIDDEN';
  END IF;

  PERFORM public.verify_discount_manager_pin_or_raise(p_store_id, p_manager_pin, 'unmark_order_item_service');

  SELECT *
  INTO v_item
  FROM public.order_items
  WHERE id = p_item_id
    AND restaurant_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_ITEM_NOT_FOUND';
  END IF;

  IF v_item.item_type <> 'menu_item' THEN
    RAISE EXCEPTION 'SERVICE_MARK_ITEM_TYPE';
  END IF;

  IF NOT COALESCE(v_item.is_service_item, false) THEN
    RAISE EXCEPTION 'SERVICE_MARK_NOT_SET';
  END IF;

  SELECT *
  INTO v_order
  FROM public.orders
  WHERE id = v_item.order_id
    AND restaurant_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  IF v_order.status IN ('completed', 'cancelled') THEN
    RAISE EXCEPTION 'ORDER_NOT_MUTABLE';
  END IF;

  IF COALESCE(v_order.order_purpose, 'customer') = 'staff_meal' THEN
    RAISE EXCEPTION 'SERVICE_MARK_PURPOSE_UNSUPPORTED';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.payments p
    WHERE p.order_id = v_order.id
  ) THEN
    RAISE EXCEPTION 'SERVICE_MARK_AFTER_PAYMENT';
  END IF;

  UPDATE public.order_items
  SET is_service_item = false,
      service_reason = NULL,
      service_marked_by = NULL,
      service_marked_at = NULL
  WHERE id = v_item.id
  RETURNING * INTO v_item;

  PERFORM public.void_active_order_discount_for_item_change(
    v_order.id,
    p_store_id,
    'order_items_changed'
  );

  INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'unmark_order_item_service',
    'order_items',
    v_item.id,
    jsonb_build_object(
      'store_id', p_store_id,
      'order_id', v_order.id,
      'reason', btrim(p_reason),
      'label', COALESCE(v_item.display_name, v_item.label),
      'quantity', v_item.quantity,
      'unit_price', v_item.unit_price
    )
  );

  RETURN v_item;
END;
$$;

REVOKE ALL ON FUNCTION public.mark_order_item_service(uuid, uuid, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.unmark_order_item_service(uuid, uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.mark_order_item_service(uuid, uuid, text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.unmark_order_item_service(uuid, uuid, text, text) TO authenticated, service_role;

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
      COALESCE(oi.is_service_item, false) AS is_service_item,
      COALESCE(mi.vat_category, 'food') AS vat_category
    FROM order_items oi
    LEFT JOIN menu_items mi ON mi.id = oi.menu_item_id
    WHERE oi.order_id = p_order_id
      AND oi.status <> 'cancelled'
      AND oi.item_type = 'menu_item'
    ORDER BY oi.created_at, oi.id
  LOOP
    IF v_item.is_service_item THEN
      UPDATE order_items
      SET vat_rate = 0,
          vat_amount = 0,
          total_amount_ex_tax = 0,
          paying_amount_inc_tax = 0
      WHERE id = v_item.id;
      CONTINUE;
    END IF;

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
    AND status <> 'cancelled'
    AND COALESCE(is_service_item, false) = false;

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

CREATE OR REPLACE FUNCTION public.enqueue_meinvoice_cash_register_job()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_tax_entity_id uuid;
  v_tax_code text;
  v_config_status text;
  v_payment_methods text[];
  v_payment_method_snapshot text;
  v_payment_summary jsonb := '[]'::jsonb;
  v_line_items_snapshot jsonb := '[]'::jsonb;
  v_status text := 'pending_manual_config';
BEGIN
  IF TG_OP <> 'UPDATE'
     OR NEW.status <> 'completed'
     OR COALESCE(OLD.status, '') = 'completed' THEN
    RETURN NEW;
  END IF;

  IF COALESCE(NEW.order_purpose, 'customer') = 'staff_meal' THEN
    RETURN NEW;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.payments p
    WHERE p.order_id = NEW.id
      AND p.is_revenue = true
  ) THEN
    RETURN NEW;
  END IF;

  SELECT r.tax_entity_id, te.tax_code
  INTO v_tax_entity_id, v_tax_code
  FROM public.restaurants r
  JOIN public.tax_entity te ON te.id = r.tax_entity_id
  WHERE r.id = NEW.restaurant_id;

  IF v_tax_entity_id IS NULL OR v_tax_code = 'PLACEHOLDER_DEV_000' THEN
    RETURN NEW;
  END IF;

  SELECT COALESCE(m.integration_status, 'needs_vendor_activation')
  INTO v_config_status
  FROM public.meinvoice_tax_entity_config m
  WHERE m.tax_entity_id = v_tax_entity_id;

  v_status := CASE
    WHEN COALESCE(v_config_status, 'needs_vendor_activation') = 'active'
     AND COALESCE((
       SELECT value = 'true'
       FROM public.system_config
       WHERE key = 'meinvoice_dispatch_enabled'
     ), false)
      THEN 'pending'
    ELSE 'pending_manual_config'
  END;

  SELECT COALESCE(array_agg(DISTINCT p.method ORDER BY p.method), ARRAY[]::text[])
  INTO v_payment_methods
  FROM public.payments p
  WHERE p.order_id = NEW.id
    AND p.is_revenue = true;

  v_payment_method_snapshot :=
    public.meinvoice_payment_method_label(v_tax_entity_id, v_payment_methods);

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'payment_id', p.id,
        'method', p.method,
        'amount', p.amount,
        'amount_portion', p.amount_portion,
        'created_at', p.created_at
      )
      ORDER BY p.created_at
    ),
    '[]'::jsonb
  )
  INTO v_payment_summary
  FROM public.payments p
  WHERE p.order_id = NEW.id
    AND p.is_revenue = true;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'order_item_id', oi.id,
        'item_type', oi.item_type,
        'display_name', COALESCE(NULLIF(oi.display_name, ''), oi.label, 'Item'),
        'quantity', oi.quantity,
        'unit_price', oi.unit_price,
        'vat_rate', oi.vat_rate,
        'vat_amount', oi.vat_amount,
        'total_amount_ex_tax', oi.total_amount_ex_tax,
        'paying_amount_inc_tax', oi.paying_amount_inc_tax
      )
      ORDER BY oi.created_at, oi.id
    ),
    '[]'::jsonb
  )
  INTO v_line_items_snapshot
  FROM public.order_items oi
  WHERE oi.order_id = NEW.id
    AND oi.status <> 'cancelled'
    AND COALESCE(oi.is_service_item, false) = false;

  INSERT INTO public.meinvoice_jobs (
    order_id,
    store_id,
    tax_entity_id,
    buyer_kind,
    buyer_snapshot,
    payment_method_snapshot,
    payment_summary,
    line_items_snapshot,
    status
  )
  VALUES (
    NEW.id,
    NEW.restaurant_id,
    v_tax_entity_id,
    'anonymous',
    jsonb_build_object(
      'customer_name',
      'Người mua không lấy hóa đơn'
    ),
    v_payment_method_snapshot,
    v_payment_summary,
    v_line_items_snapshot,
    v_status
  )
  ON CONFLICT (order_id) DO NOTHING;

  RETURN NEW;
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'meInvoice enqueue skipped for order %, error: %', NEW.id, SQLERRM;
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION public.enqueue_meinvoice_cash_register_job() IS
  'Creates the restaurant MISA meInvoice first-issuance queue row after revenue order completion. Staff meals, non-revenue completions, and service-item lines are skipped, and errors never block payment completion.';

COMMIT;
