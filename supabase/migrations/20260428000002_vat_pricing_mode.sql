BEGIN;

ALTER TABLE public.restaurants
  ADD COLUMN IF NOT EXISTS vat_pricing_mode text NOT NULL DEFAULT 'exclusive'
  CHECK (vat_pricing_mode IN ('exclusive', 'inclusive'));

COMMENT ON COLUMN public.restaurants.vat_pricing_mode IS
  'VAT pricing mode for POS menu prices. exclusive=current behavior adds VAT on top; inclusive=treats menu price as VAT-included and derives pretax/VAT at payment time.';

DROP FUNCTION IF EXISTS public.process_payment(uuid, uuid, numeric, text);
DROP FUNCTION IF EXISTS public.request_red_invoice(uuid, text, text, text, text, text, text);
DROP FUNCTION IF EXISTS public.request_red_invoice(uuid, uuid, text, text, text, text, text, text);
DROP FUNCTION IF EXISTS public.search_b2b_buyers(uuid, text);
DROP FUNCTION IF EXISTS public.admin_update_restaurant_settings(uuid, text, text, text, numeric);
DROP FUNCTION IF EXISTS public.admin_update_restaurant_settings(uuid, text, text, text, numeric, text);

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

CREATE OR REPLACE FUNCTION public.request_red_invoice(
  p_order_id uuid,
  p_buyer_tax_code text,
  p_buyer_name text,
  p_buyer_address text,
  p_receiver_email text,
  p_receiver_email_cc text DEFAULT NULL,
  p_buyer_tel text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_actor users%ROWTYPE;
  v_job einvoice_jobs%ROWTYPE;
  v_shop einvoice_shop%ROWTYPE;
  v_te tax_entity%ROWTYPE;
  v_restaurant restaurants%ROWTYPE;
  v_ref_id text;
  v_store_code text;
  v_store_name text;
  v_serial_no text;
  v_wt05_payload jsonb;
BEGIN
  SELECT * INTO v_actor
  FROM users
  WHERE auth_id = auth.uid() AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('cashier','admin','super_admin') THEN
    RAISE EXCEPTION 'FORBIDDEN';
  END IF;

  IF p_receiver_email IS NULL OR trim(p_receiver_email) = '' THEN
    RAISE EXCEPTION 'EMAIL_REQUIRED';
  END IF;

  SELECT * INTO v_job
  FROM einvoice_jobs
  WHERE order_id = p_order_id
  ORDER BY created_at DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'JOB_NOT_FOUND';
  END IF;

  IF v_job.status IN ('failed_terminal') THEN
    RAISE EXCEPTION 'JOB_FAILED';
  END IF;

  SELECT * INTO v_shop FROM einvoice_shop WHERE id = v_job.einvoice_shop_id;
  SELECT * INTO v_te FROM tax_entity WHERE id = v_job.tax_entity_id;
  SELECT * INTO v_restaurant FROM restaurants WHERE tax_entity_id = v_job.tax_entity_id LIMIT 1;

  v_store_code := COALESCE(v_shop.provider_shop_code, v_te.tax_code);
  v_store_name := COALESCE(v_shop.shop_name, v_restaurant.name, 'GLOBOSVN');

  SELECT (t->>'serial_no')
  INTO v_serial_no
  FROM jsonb_array_elements(COALESCE(v_shop.templates, '[]'::jsonb)) AS t
  WHERE (t->>'status_code') = '1'
  LIMIT 1;

  v_serial_no := COALESCE(v_serial_no, 'C26MTT');
  v_ref_id := v_job.ref_id;

  SELECT jsonb_build_object(
    'seller', jsonb_build_object(
      'tax_code', v_te.tax_code,
      'store_code', v_store_code,
      'store_name', v_store_name
    ),
    'invoices', jsonb_build_array(
      (v_job.send_order_payload) ||
      jsonb_build_object(
        'ref_id', v_ref_id,
        'invoice_type', '0',
        'form_no', '1',
        'serial_no', v_serial_no,
        'cqt_code', '',
        'buyer_comp_name', COALESCE(p_buyer_name, ''),
        'buyer_tax_code', COALESCE(p_buyer_tax_code, ''),
        'buyer_address', COALESCE(p_buyer_address, ''),
        'buyer_tel', COALESCE(p_buyer_tel, ''),
        'buyer_email', p_receiver_email,
        'buyer_email_cc', COALESCE(p_receiver_email_cc, ''),
        'tot_amount', (
          SELECT COALESCE(SUM(COALESCE(oi.total_amount_ex_tax, (oi.unit_price * oi.quantity))::numeric), 0)
          FROM order_items oi
          WHERE oi.order_id = p_order_id AND oi.status <> 'cancelled'
        ),
        'tot_vat_amount', (
          SELECT COALESCE(SUM(oi.vat_amount::numeric), 0)
          FROM order_items oi
          WHERE oi.order_id = p_order_id AND oi.status <> 'cancelled'
        ),
        'tot_dc_amount', 0,
        'tot_pay_amount', (
          SELECT COALESCE(SUM(oi.paying_amount_inc_tax::numeric), 0)
          FROM order_items oi
          WHERE oi.order_id = p_order_id AND oi.status <> 'cancelled'
        )
      )
    )
  ) INTO v_wt05_payload;

  UPDATE einvoice_jobs
  SET
    redinvoice_requested = TRUE,
    request_einvoice_payload = v_wt05_payload,
    request_einvoice_retry_count = 0,
    request_einvoice_next_retry_at = NULL,
    updated_at = now()
  WHERE id = v_job.id;

  IF p_buyer_tax_code IS NOT NULL AND p_buyer_tax_code <> '' AND v_actor.restaurant_id IS NOT NULL THEN
    INSERT INTO b2b_buyer_cache (
      store_id, buyer_tax_code, tax_company_name,
      tax_address, receiver_email, receiver_email_cc,
      first_used_at, last_used_at, use_count, tax_entity_id
    ) VALUES (
      v_actor.restaurant_id,
      p_buyer_tax_code,
      COALESCE(p_buyer_name, ''),
      COALESCE(p_buyer_address, ''),
      p_receiver_email,
      p_receiver_email_cc,
      now(), now(), 1,
      v_te.id
    )
    ON CONFLICT (store_id, buyer_tax_code) DO UPDATE SET
      tax_company_name = EXCLUDED.tax_company_name,
      tax_address = EXCLUDED.tax_address,
      receiver_email = EXCLUDED.receiver_email,
      receiver_email_cc = EXCLUDED.receiver_email_cc,
      last_used_at = now(),
      use_count = b2b_buyer_cache.use_count + 1;
  END IF;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'request_red_invoice',
    'einvoice_jobs',
    v_job.id,
    jsonb_build_object(
      'order_id', p_order_id,
      'buyer_tax_code', p_buyer_tax_code,
      'receiver_email', p_receiver_email
    )
  );

  RETURN jsonb_build_object('ok', true, 'job_id', v_job.id, 'ref_id', v_ref_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.request_red_invoice(
  p_order_id uuid,
  p_store_id uuid,
  p_buyer_tax_code text,
  p_buyer_name text,
  p_buyer_address text,
  p_receiver_email text,
  p_receiver_email_cc text DEFAULT NULL,
  p_buyer_tel text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_actor users%ROWTYPE;
  v_order orders%ROWTYPE;
  v_job einvoice_jobs%ROWTYPE;
  v_shop einvoice_shop%ROWTYPE;
  v_te tax_entity%ROWTYPE;
  v_restaurant restaurants%ROWTYPE;
  v_ref_id text;
  v_store_code text;
  v_store_name text;
  v_serial_no text;
  v_wt05_payload jsonb;
BEGIN
  SELECT * INTO v_actor
  FROM users
  WHERE auth_id = auth.uid() AND is_active = TRUE
  LIMIT 1;

  IF NOT FOUND OR v_actor.role NOT IN ('cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin') THEN
    RAISE EXCEPTION 'FORBIDDEN';
  END IF;

  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'STORE_REQUIRED';
  END IF;

  IF NOT is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'STORE_ACCESS_FORBIDDEN';
  END IF;

  IF p_receiver_email IS NULL OR trim(p_receiver_email) = '' THEN
    RAISE EXCEPTION 'EMAIL_REQUIRED';
  END IF;

  SELECT * INTO v_order
  FROM orders
  WHERE id = p_order_id
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  IF v_order.restaurant_id IS DISTINCT FROM p_store_id THEN
    RAISE EXCEPTION 'ORDER_STORE_MISMATCH';
  END IF;

  SELECT * INTO v_job
  FROM einvoice_jobs
  WHERE order_id = p_order_id
  ORDER BY created_at DESC
  LIMIT 1;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'JOB_NOT_FOUND';
  END IF;

  IF v_job.status IN ('failed_terminal') THEN
    RAISE EXCEPTION 'JOB_FAILED';
  END IF;

  SELECT * INTO v_shop FROM einvoice_shop WHERE id = v_job.einvoice_shop_id;
  SELECT * INTO v_te FROM tax_entity WHERE id = v_job.tax_entity_id;
  SELECT * INTO v_restaurant FROM restaurants WHERE id = p_store_id;

  v_store_code := COALESCE(v_shop.provider_shop_code, v_te.tax_code);
  v_store_name := COALESCE(v_shop.shop_name, v_restaurant.name, 'GLOBOSVN');

  SELECT (t->>'serial_no')
  INTO v_serial_no
  FROM jsonb_array_elements(COALESCE(v_shop.templates, '[]'::jsonb)) AS t
  WHERE (t->>'status_code') = '1'
  LIMIT 1;

  v_serial_no := COALESCE(v_serial_no, 'C26MTT');
  v_ref_id := v_job.ref_id;

  SELECT jsonb_build_object(
    'seller', jsonb_build_object(
      'tax_code', v_te.tax_code,
      'store_code', v_store_code,
      'store_name', v_store_name
    ),
    'invoices', jsonb_build_array(
      (v_job.send_order_payload) ||
      jsonb_build_object(
        'ref_id', v_ref_id,
        'invoice_type', '0',
        'form_no', '1',
        'serial_no', v_serial_no,
        'cqt_code', '',
        'buyer_comp_name', COALESCE(p_buyer_name, ''),
        'buyer_tax_code', COALESCE(p_buyer_tax_code, ''),
        'buyer_address', COALESCE(p_buyer_address, ''),
        'buyer_tel', COALESCE(p_buyer_tel, ''),
        'buyer_email', p_receiver_email,
        'buyer_email_cc', COALESCE(p_receiver_email_cc, ''),
        'tot_amount', (
          SELECT COALESCE(SUM(COALESCE(oi.total_amount_ex_tax, (oi.unit_price * oi.quantity))::numeric), 0)
          FROM order_items oi
          WHERE oi.order_id = p_order_id AND oi.status <> 'cancelled'
        ),
        'tot_vat_amount', (
          SELECT COALESCE(SUM(oi.vat_amount::numeric), 0)
          FROM order_items oi
          WHERE oi.order_id = p_order_id AND oi.status <> 'cancelled'
        ),
        'tot_dc_amount', 0,
        'tot_pay_amount', (
          SELECT COALESCE(SUM(oi.paying_amount_inc_tax::numeric), 0)
          FROM order_items oi
          WHERE oi.order_id = p_order_id AND oi.status <> 'cancelled'
        )
      )
    )
  ) INTO v_wt05_payload;

  UPDATE einvoice_jobs
  SET
    redinvoice_requested = TRUE,
    request_einvoice_payload = v_wt05_payload,
    request_einvoice_retry_count = 0,
    request_einvoice_next_retry_at = NULL,
    updated_at = now()
  WHERE id = v_job.id;

  IF p_buyer_tax_code IS NOT NULL AND p_buyer_tax_code <> '' THEN
    INSERT INTO b2b_buyer_cache (
      store_id, buyer_tax_code, tax_company_name,
      tax_address, receiver_email, receiver_email_cc,
      first_used_at, last_used_at, use_count, tax_entity_id
    ) VALUES (
      p_store_id,
      p_buyer_tax_code,
      COALESCE(p_buyer_name, ''),
      COALESCE(p_buyer_address, ''),
      p_receiver_email,
      p_receiver_email_cc,
      now(), now(), 1,
      v_te.id
    )
    ON CONFLICT (store_id, buyer_tax_code) DO UPDATE SET
      tax_company_name = EXCLUDED.tax_company_name,
      tax_address = EXCLUDED.tax_address,
      receiver_email = EXCLUDED.receiver_email,
      receiver_email_cc = EXCLUDED.receiver_email_cc,
      last_used_at = now(),
      use_count = b2b_buyer_cache.use_count + 1;
  END IF;

  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'request_red_invoice',
    'einvoice_jobs',
    v_job.id,
    jsonb_build_object(
      'order_id', p_order_id,
      'store_id', p_store_id,
      'buyer_tax_code', p_buyer_tax_code,
      'receiver_email', p_receiver_email
    )
  );

  RETURN jsonb_build_object('ok', true, 'job_id', v_job.id, 'ref_id', v_ref_id);
END;
$$;

CREATE OR REPLACE FUNCTION public.search_b2b_buyers(
  p_store_id uuid,
  p_query text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_tax_entity_id uuid;
  v_query text := btrim(COALESCE(p_query, ''));
  v_result jsonb;
BEGIN
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'STORE_REQUIRED';
  END IF;

  IF NOT is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) s(store_id)
       WHERE s.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'STORE_ACCESS_FORBIDDEN';
  END IF;

  IF length(v_query) < 2 THEN
    RETURN '[]'::jsonb;
  END IF;

  SELECT tax_entity_id
  INTO v_tax_entity_id
  FROM restaurants
  WHERE id = p_store_id;

  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'buyer_tax_code', ranked.buyer_tax_code,
        'tax_company_name', ranked.tax_company_name,
        'tax_address', ranked.tax_address,
        'receiver_email', ranked.receiver_email,
        'receiver_email_cc', ranked.receiver_email_cc
      )
      ORDER BY ranked.store_priority DESC, ranked.last_used_at DESC
    ),
    '[]'::jsonb
  )
  INTO v_result
  FROM (
    SELECT
      buyer_tax_code,
      tax_company_name,
      tax_address,
      receiver_email,
      receiver_email_cc,
      last_used_at,
      (store_id = p_store_id) AS store_priority
    FROM b2b_buyer_cache
    WHERE (
        store_id = p_store_id
        OR (v_tax_entity_id IS NOT NULL AND tax_entity_id = v_tax_entity_id)
      )
      AND (
        buyer_tax_code ILIKE v_query || '%'
        OR tax_company_name ILIKE '%' || v_query || '%'
      )
    ORDER BY (store_id = p_store_id) DESC, last_used_at DESC
    LIMIT 5
  ) ranked;

  RETURN v_result;
END;
$$;

DROP POLICY IF EXISTS "brand_master_admin_read" ON public.brand_master;
CREATE POLICY "brand_master_admin_read" ON public.brand_master
  FOR SELECT USING (is_super_admin() OR has_any_role(ARRAY['admin','store_admin','brand_admin']));

DROP POLICY IF EXISTS "tax_entity_admin_read" ON public.tax_entity;
CREATE POLICY "tax_entity_admin_read" ON public.tax_entity
  FOR SELECT USING (is_super_admin() OR has_any_role(ARRAY['admin','store_admin','brand_admin']));

DROP POLICY IF EXISTS "einvoice_shop_admin_read" ON public.einvoice_shop;
CREATE POLICY "einvoice_shop_admin_read" ON public.einvoice_shop
  FOR SELECT USING (is_super_admin() OR has_any_role(ARRAY['admin','store_admin','brand_admin']));

DROP POLICY IF EXISTS "system_config_admin_read" ON public.system_config;
CREATE POLICY "system_config_admin_read" ON public.system_config
  FOR SELECT USING (is_super_admin() OR has_any_role(ARRAY['admin','store_admin','brand_admin']));

DROP POLICY IF EXISTS "b2b_buyer_cache_store_select" ON public.b2b_buyer_cache;
CREATE POLICY "b2b_buyer_cache_store_select" ON public.b2b_buyer_cache
  FOR SELECT USING (
    is_super_admin() OR
    (has_any_role(ARRAY['cashier','admin','store_admin','brand_admin']) AND (
      store_id = get_user_store_id() OR
      tax_entity_id = get_user_tax_entity_id()
    ))
  );

DROP POLICY IF EXISTS "b2b_buyer_cache_store_insert" ON public.b2b_buyer_cache;
CREATE POLICY "b2b_buyer_cache_store_insert" ON public.b2b_buyer_cache
  FOR INSERT WITH CHECK (
    is_super_admin() OR
    (has_any_role(ARRAY['cashier','admin','store_admin','brand_admin']) AND store_id = get_user_store_id())
  );

DROP POLICY IF EXISTS "b2b_buyer_cache_store_update" ON public.b2b_buyer_cache;
CREATE POLICY "b2b_buyer_cache_store_update" ON public.b2b_buyer_cache
  FOR UPDATE
  USING (is_super_admin() OR (has_any_role(ARRAY['cashier','admin','store_admin','brand_admin']) AND store_id = get_user_store_id()))
  WITH CHECK (is_super_admin() OR (has_any_role(ARRAY['cashier','admin','store_admin','brand_admin']) AND store_id = get_user_store_id()));

DROP POLICY IF EXISTS "b2b_buyer_cache_admin_delete" ON public.b2b_buyer_cache;
CREATE POLICY "b2b_buyer_cache_admin_delete" ON public.b2b_buyer_cache
  FOR DELETE USING (is_super_admin() OR (has_any_role(ARRAY['admin','store_admin','brand_admin']) AND store_id = get_user_store_id()));

DROP POLICY IF EXISTS "store_tax_history_admin_read" ON public.store_tax_entity_history;
CREATE POLICY "store_tax_history_admin_read" ON public.store_tax_entity_history
  FOR SELECT USING (is_super_admin() OR (has_any_role(ARRAY['admin','store_admin','brand_admin']) AND store_id = get_user_store_id()));

DROP POLICY IF EXISTS "einvoice_jobs_admin_read" ON public.einvoice_jobs;
CREATE POLICY "einvoice_jobs_admin_read" ON public.einvoice_jobs
  FOR SELECT USING (
    is_super_admin() OR
    (has_any_role(ARRAY['admin','store_admin','brand_admin']) AND (
      EXISTS (
        SELECT 1 FROM orders o
        WHERE o.id = einvoice_jobs.order_id AND o.restaurant_id = get_user_store_id()
      )
      OR einvoice_jobs.tax_entity_id = get_user_tax_entity_id()
    ))
  );

DROP POLICY IF EXISTS "einvoice_events_admin_read" ON public.einvoice_events;
CREATE POLICY "einvoice_events_admin_read" ON public.einvoice_events
  FOR SELECT USING (
    is_super_admin() OR
    (has_any_role(ARRAY['admin','store_admin','brand_admin']) AND (
      job_id IS NULL OR
      EXISTS (
        SELECT 1 FROM einvoice_jobs ej
        WHERE ej.id = einvoice_events.job_id AND (
          EXISTS (SELECT 1 FROM orders o WHERE o.id = ej.order_id AND o.restaurant_id = get_user_store_id())
          OR ej.tax_entity_id = get_user_tax_entity_id()
        )
      )
    ))
  );

CREATE OR REPLACE FUNCTION public.admin_update_restaurant_settings(
  p_store_id uuid,
  p_name text,
  p_operation_mode text,
  p_address text DEFAULT NULL,
  p_per_person_charge numeric DEFAULT NULL,
  p_vat_pricing_mode text DEFAULT 'exclusive'
) RETURNS public.restaurants AS $$
DECLARE
  v_existing public.restaurants%ROWTYPE;
  v_updated public.restaurants%ROWTYPE;
  v_changed_fields text[] := ARRAY[]::text[];
  v_old_values jsonb := '{}'::jsonb;
  v_new_values jsonb := '{}'::jsonb;
  v_name text := NULLIF(btrim(COALESCE(p_name, '')), '');
  v_operation_mode text := lower(COALESCE(p_operation_mode, ''));
  v_address text := NULLIF(btrim(COALESCE(p_address, '')), '');
  v_vat_pricing_mode text := lower(COALESCE(p_vat_pricing_mode, 'exclusive'));
BEGIN
  IF p_store_id IS NULL THEN
    RAISE EXCEPTION 'RESTAURANT_ID_REQUIRED';
  END IF;

  IF v_name IS NULL THEN
    RAISE EXCEPTION 'RESTAURANT_NAME_REQUIRED';
  END IF;

  IF v_operation_mode = '' THEN
    RAISE EXCEPTION 'RESTAURANT_OPERATION_MODE_REQUIRED';
  END IF;

  IF v_vat_pricing_mode NOT IN ('exclusive', 'inclusive') THEN
    RAISE EXCEPTION 'RESTAURANT_VAT_PRICING_MODE_INVALID';
  END IF;

  SELECT *
  INTO v_existing
  FROM public.restaurants
  WHERE id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'RESTAURANT_NOT_FOUND';
  END IF;

  PERFORM public.require_admin_actor_for_restaurant(v_existing.id);

  IF v_name IS DISTINCT FROM v_existing.name THEN
    v_changed_fields := array_append(v_changed_fields, 'name');
    v_old_values := v_old_values || jsonb_build_object('name', v_existing.name);
    v_new_values := v_new_values || jsonb_build_object('name', v_name);
  END IF;

  IF v_address IS DISTINCT FROM v_existing.address THEN
    v_changed_fields := array_append(v_changed_fields, 'address');
    v_old_values := v_old_values || jsonb_build_object('address', v_existing.address);
    v_new_values := v_new_values || jsonb_build_object('address', v_address);
  END IF;

  IF v_operation_mode IS DISTINCT FROM v_existing.operation_mode THEN
    v_changed_fields := array_append(v_changed_fields, 'operation_mode');
    v_old_values := v_old_values || jsonb_build_object('operation_mode', v_existing.operation_mode);
    v_new_values := v_new_values || jsonb_build_object('operation_mode', v_operation_mode);
  END IF;

  IF p_per_person_charge IS DISTINCT FROM v_existing.per_person_charge THEN
    v_changed_fields := array_append(v_changed_fields, 'per_person_charge');
    v_old_values := v_old_values || jsonb_build_object('per_person_charge', v_existing.per_person_charge);
    v_new_values := v_new_values || jsonb_build_object('per_person_charge', p_per_person_charge);
  END IF;

  IF v_vat_pricing_mode IS DISTINCT FROM COALESCE(v_existing.vat_pricing_mode, 'exclusive') THEN
    v_changed_fields := array_append(v_changed_fields, 'vat_pricing_mode');
    v_old_values := v_old_values || jsonb_build_object('vat_pricing_mode', v_existing.vat_pricing_mode);
    v_new_values := v_new_values || jsonb_build_object('vat_pricing_mode', v_vat_pricing_mode);
  END IF;

  UPDATE public.restaurants
  SET name = v_name,
      address = v_address,
      operation_mode = v_operation_mode,
      per_person_charge = p_per_person_charge,
      vat_pricing_mode = v_vat_pricing_mode
  WHERE id = v_existing.id
  RETURNING * INTO v_updated;

  IF COALESCE(array_length(v_changed_fields, 1), 0) > 0 THEN
    INSERT INTO public.audit_logs (actor_id, action, entity_type, entity_id, details)
    VALUES (
      auth.uid(),
      'admin_update_restaurant_settings',
      'restaurants',
      v_updated.id,
      jsonb_build_object(
        'store_id', v_updated.id,
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

COMMIT;
