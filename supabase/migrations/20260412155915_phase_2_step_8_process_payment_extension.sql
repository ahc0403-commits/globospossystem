BEGIN;

CREATE OR REPLACE FUNCTION public.generate_uuidv7()
RETURNS text
LANGUAGE plpgsql
AS $$
DECLARE
  ts_ms   bigint := (extract(epoch from clock_timestamp()) * 1000)::bigint;
  rand_b  bytea  := gen_random_bytes(10);
  g1      text;
  g2      text;
  g3      text;
  vbyte   int;
  g4      text;
  g5      text;
BEGIN
  g1 := lpad(to_hex((ts_ms >> 16) & x'ffffffff'::bigint), 8, '0');
  g2 := lpad(to_hex(ts_ms & x'ffff'::bigint), 4, '0');
  g3 := '7' || substr(encode(rand_b, 'hex'), 1, 3);
  vbyte := (get_byte(rand_b, 2) & x'3f'::int) | x'80'::int;
  g4 := lpad(to_hex(vbyte), 2, '0') || substr(encode(rand_b, 'hex'), 7, 2);
  g5 := substr(encode(rand_b, 'hex'), 9, 12);
  RETURN g1 || '-' || g2 || '-' || g3 || '-' || g4 || '-' || g5;
END;
$$;

COMMENT ON FUNCTION public.generate_uuidv7() IS 'Generates UUIDv7-format string (version nibble=7, RFC 4122 variant). Used for einvoice_jobs.ref_id (Invariant I8).';

CREATE OR REPLACE FUNCTION public.process_payment(
  p_order_id       uuid,
  p_restaurant_id  uuid,
  p_amount         numeric,
  p_method         text
)
RETURNS payments
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_actor            users%ROWTYPE;
  v_order            orders%ROWTYPE;
  v_payment          payments%ROWTYPE;
  v_brand            brands%ROWTYPE;
  v_table_id         uuid;
  v_item             RECORD;
  v_recipe           RECORD;
  v_deduct_qty       decimal(12,3);
  v_food_subtotal    decimal(15,2) := 0;
  v_alcohol_subtotal decimal(15,2) := 0;
  v_sc_rate          decimal(5,2)  := 0;
  v_sc_pretax        decimal(15,2);
  v_sc_vat           decimal(15,2);
  v_sc_total         decimal(15,2);
  v_ref_id           text;
  v_tax_entity_id    uuid;
  v_einvoice_shop_id uuid;
  v_send_payload     jsonb;
  v_bill_products    jsonb := '[]'::jsonb;
  v_pretax           decimal(15,2);
  v_vat_rate         decimal(5,2);
  v_vat_amt          decimal(15,2);
  v_total_inc        decimal(15,2);
BEGIN
  -- Auth
  SELECT * INTO v_actor FROM users WHERE auth_id = auth.uid() AND is_active = TRUE LIMIT 1;
  IF NOT FOUND OR v_actor.role NOT IN ('cashier','admin','super_admin') THEN RAISE EXCEPTION 'PAYMENT_FORBIDDEN'; END IF;
  IF v_actor.role <> 'super_admin' AND v_actor.restaurant_id <> p_restaurant_id THEN RAISE EXCEPTION 'PAYMENT_FORBIDDEN'; END IF;

  IF p_method NOT IN ('CASH','CREDITCARD','ATM','MOMO','ZALOPAY','VNPAY','SHOPEEPAY','BANKTRANSFER','VOUCHER','CREDITSALE','OTHER') THEN
    RAISE EXCEPTION 'INVALID_PAYMENT_METHOD';
  END IF;

  -- Lock order
  SELECT * INTO v_order FROM orders WHERE id = p_order_id AND restaurant_id = p_restaurant_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ORDER_NOT_FOUND'; END IF;
  IF v_order.status IN ('completed','cancelled') THEN RAISE EXCEPTION 'ORDER_NOT_PAYABLE'; END IF;
  IF EXISTS (SELECT 1 FROM payments WHERE order_id = p_order_id) THEN RAISE EXCEPTION 'PAYMENT_ALREADY_EXISTS'; END IF;
  IF p_amount <= 0 THEN RAISE EXCEPTION 'PAYMENT_AMOUNT_INVALID'; END IF;

  -- Brand: service charge
  SELECT b.* INTO v_brand FROM restaurants r JOIN brands b ON b.id = r.brand_id WHERE r.id = p_restaurant_id;
  IF FOUND AND v_brand.service_charge_enabled THEN v_sc_rate := COALESCE(v_brand.service_charge_rate, 0); END IF;

  -- VAT calculation: update existing menu_item order_items
  FOR v_item IN
    SELECT oi.id, oi.unit_price, oi.quantity, oi.display_name, oi.label,
           COALESCE(mi.vat_category, 'food') AS vat_category
    FROM order_items oi
    LEFT JOIN menu_items mi ON mi.id = oi.menu_item_id
    WHERE oi.order_id = p_order_id AND oi.status <> 'cancelled' AND oi.item_type = 'menu_item'
  LOOP
    v_pretax    := ROUND(v_item.unit_price * v_item.quantity, 2);
    v_vat_rate  := CASE v_item.vat_category WHEN 'alcohol' THEN 10 ELSE 8 END;
    v_vat_amt   := ROUND(v_pretax * v_vat_rate / 100, 2);
    v_total_inc := v_pretax + v_vat_amt;

    UPDATE order_items SET
      vat_rate = v_vat_rate, vat_amount = v_vat_amt,
      total_amount_ex_tax = v_pretax, paying_amount_inc_tax = v_total_inc
    WHERE id = v_item.id;

    IF v_item.vat_category = 'alcohol' THEN
      v_alcohol_subtotal := v_alcohol_subtotal + v_pretax;
    ELSE
      v_food_subtotal := v_food_subtotal + v_pretax;
    END IF;

    v_bill_products := v_bill_products || jsonb_build_object(
      'item_name', COALESCE(NULLIF(v_item.display_name,''), v_item.label, 'Item'),
      'unit_price', v_item.unit_price, 'quantity', v_item.quantity, 'uom', 'EA',
      'total_amount', v_pretax, 'vat_rate', v_vat_rate, 'vat_amount', v_vat_amt, 'paying_amount', v_total_inc
    );
  END LOOP;

  -- Service charge: food
  IF v_sc_rate > 0 AND v_food_subtotal > 0 THEN
    v_sc_pretax := ROUND(v_food_subtotal * v_sc_rate / 100, 2);
    v_sc_vat    := ROUND(v_sc_pretax * 8 / 100, 2);
    v_sc_total  := v_sc_pretax + v_sc_vat;
    INSERT INTO order_items (order_id, restaurant_id, item_type, display_name, menu_item_id, unit_price, quantity, label, status, vat_rate, vat_amount, total_amount_ex_tax, paying_amount_inc_tax)
    VALUES (p_order_id, p_restaurant_id, 'service_charge', 'Service Charge (Food)', NULL, v_sc_pretax, 1, 'Service Charge (Food)', 'served', 8, v_sc_vat, v_sc_pretax, v_sc_total);
    v_bill_products := v_bill_products || jsonb_build_object('item_name','Service Charge (Food)','unit_price',v_sc_pretax,'quantity',1,'uom','EA','total_amount',v_sc_pretax,'vat_rate',8,'vat_amount',v_sc_vat,'paying_amount',v_sc_total);
  END IF;

  -- Service charge: alcohol
  IF v_sc_rate > 0 AND v_alcohol_subtotal > 0 THEN
    v_sc_pretax := ROUND(v_alcohol_subtotal * v_sc_rate / 100, 2);
    v_sc_vat    := ROUND(v_sc_pretax * 10 / 100, 2);
    v_sc_total  := v_sc_pretax + v_sc_vat;
    INSERT INTO order_items (order_id, restaurant_id, item_type, display_name, menu_item_id, unit_price, quantity, label, status, vat_rate, vat_amount, total_amount_ex_tax, paying_amount_inc_tax)
    VALUES (p_order_id, p_restaurant_id, 'service_charge', 'Service Charge (Alcohol)', NULL, v_sc_pretax, 1, 'Service Charge (Alcohol)', 'served', 10, v_sc_vat, v_sc_pretax, v_sc_total);
    v_bill_products := v_bill_products || jsonb_build_object('item_name','Service Charge (Alcohol)','unit_price',v_sc_pretax,'quantity',1,'uom','EA','total_amount',v_sc_pretax,'vat_rate',10,'vat_amount',v_sc_vat,'paying_amount',v_sc_total);
  END IF;

  -- Payment
  INSERT INTO payments (order_id, restaurant_id, amount, method, processed_by, is_revenue, amount_portion)
  VALUES (p_order_id, p_restaurant_id, p_amount, p_method, auth.uid(), TRUE, p_amount)
  RETURNING * INTO v_payment;

  -- Complete order + release table
  UPDATE orders SET status = 'completed', updated_at = now() WHERE id = p_order_id RETURNING table_id INTO v_table_id;
  IF v_table_id IS NOT NULL THEN UPDATE tables SET status = 'available', updated_at = now() WHERE id = v_table_id; END IF;

  -- Inventory deduction
  FOR v_item IN
    SELECT oi.id AS order_item_id, oi.menu_item_id, oi.quantity AS ordered_qty
    FROM order_items oi
    WHERE oi.order_id = p_order_id AND oi.menu_item_id IS NOT NULL AND oi.status <> 'cancelled' AND oi.item_type = 'menu_item'
  LOOP
    FOR v_recipe IN
      SELECT mr.ingredient_id, mr.quantity_g FROM menu_recipes mr WHERE mr.menu_item_id = v_item.menu_item_id AND mr.restaurant_id = p_restaurant_id
    LOOP
      v_deduct_qty := v_item.ordered_qty * v_recipe.quantity_g;
      UPDATE inventory_items SET current_stock = current_stock - v_deduct_qty, updated_at = now() WHERE id = v_recipe.ingredient_id AND restaurant_id = p_restaurant_id;
      INSERT INTO inventory_transactions (restaurant_id, ingredient_id, transaction_type, quantity_g, reference_type, reference_id, created_by)
      VALUES (p_restaurant_id, v_recipe.ingredient_id, 'deduct', -v_deduct_qty, 'order_item', v_item.order_item_id, auth.uid());
    END LOOP;
  END LOOP;

  -- Create einvoice_jobs (skip placeholder tax_entity)
  SELECT r.tax_entity_id INTO v_tax_entity_id FROM restaurants r WHERE r.id = p_restaurant_id;

  IF v_tax_entity_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM tax_entity WHERE id = v_tax_entity_id AND tax_code = 'PLACEHOLDER_DEV_000'
  ) THEN
    SELECT id INTO v_einvoice_shop_id FROM einvoice_shop WHERE tax_entity_id = v_tax_entity_id LIMIT 1;

    IF v_einvoice_shop_id IS NOT NULL THEN
      v_ref_id := generate_uuidv7();

      SELECT jsonb_build_object(
        'ref_id', v_ref_id,
        'store_code', COALESCE(es.provider_shop_code, te.tax_code),
        'store_name', COALESCE(es.shop_name, r.name),
        'order_date', to_char(now() AT TIME ZONE 'Asia/Ho_Chi_Minh', 'YYYYMMDD'),
        'order_time', to_char(now() AT TIME ZONE 'Asia/Ho_Chi_Minh', 'YYYYMMDDHH24MISS'),
        'pos_number', 1,
        'order_id', (extract(epoch from v_order.created_at) * 1000)::bigint % 1000000,
        'trans_type', 1,
        'payment_method', p_method,
        'list_product', v_bill_products
      ) INTO v_send_payload
      FROM restaurants r
      JOIN tax_entity te ON te.id = v_tax_entity_id
      JOIN einvoice_shop es ON es.id = v_einvoice_shop_id
      WHERE r.id = p_restaurant_id;

      INSERT INTO einvoice_jobs (ref_id, order_id, tax_entity_id, einvoice_shop_id, redinvoice_requested, status, send_order_payload)
      VALUES (v_ref_id, p_order_id, v_tax_entity_id, v_einvoice_shop_id, FALSE, 'pending', v_send_payload);
    END IF;
  END IF;

  -- Audit
  INSERT INTO audit_logs (actor_id, action, entity_type, entity_id, details)
  VALUES (auth.uid(), 'process_payment', 'payments', v_payment.id,
    jsonb_build_object('restaurant_id',p_restaurant_id,'order_id',p_order_id,'amount',p_amount,'method',p_method,'ref_id',v_ref_id,'einvoice_job_created',v_ref_id IS NOT NULL));

  RETURN v_payment;
END;
$$;

COMMIT;;
