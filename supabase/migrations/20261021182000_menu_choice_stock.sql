-- Extra recipe usage is frozen with the customer selection; consuming once uses
-- the same cancellation/partial-payment rules as the base recipe.
-- production-gate: self-verifying
BEGIN;
CREATE FUNCTION public.order_choice_consumption(p_order_id uuid,p_store_id uuid)
RETURNS TABLE(order_item_id uuid,ingredient_id uuid,quantity numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_catalog AS $$
 WITH lines AS MATERIALIZED (
  SELECT oi.id,oi.menu_item_id,oi.menu_option_snapshot,
   CASE WHEN oi.status='cancelled' THEN oi.cancelled_consumed_quantity
    ELSE oi.quantity+oi.cancelled_consumed_quantity END qty
  FROM public.order_items oi WHERE oi.order_id=p_order_id AND oi.restaurant_id=p_store_id
   AND oi.item_type='menu_item' AND (oi.status<>'cancelled' OR oi.cancelled_consumed_quantity>0)
   AND NOT (coalesce(nullif(current_setting('pos.direct_combo_snapshot',true),''),'{}')::jsonb ? oi.id::text)
 ), usage AS (
  SELECT l.id,mr.ingredient_id,l.qty*mr.quantity_g quantity FROM lines l JOIN public.menu_recipes mr
   ON mr.menu_item_id=l.menu_item_id AND mr.restaurant_id=p_store_id WHERE NOT l.menu_option_snapshot ? 'recipe_basis'
  UNION ALL
  SELECT l.id,(r->>'ingredient_id')::uuid,(l.qty*(r->>'quantity_g')::numeric)/(l.menu_option_snapshot->'recipe_basis'->>'quantity')::numeric
   FROM lines l CROSS JOIN LATERAL jsonb_array_elements(coalesce(l.menu_option_snapshot->'recipe_basis'->'items','[]'))r
  UNION ALL
  SELECT l.id,(r->>'ingredient_id')::uuid,l.qty*(r->>'quantity_g')::numeric
   FROM lines l CROSS JOIN LATERAL jsonb_array_elements(coalesce(l.menu_option_snapshot->'recipe_additions','[]'))r
 ) SELECT u.id,u.ingredient_id,sum(u.quantity) FROM usage u GROUP BY u.id,u.ingredient_id;
$$;
REVOKE ALL ON FUNCTION public.order_choice_consumption(uuid,uuid) FROM PUBLIC,anon,authenticated,service_role;

CREATE OR REPLACE FUNCTION "public"."process_payment_without_scoped_promotions"("p_order_id" "uuid", "p_store_id" "uuid", "p_amount" numeric, "p_method" "text") RETURNS "public"."payments"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth'
    AS $$
DECLARE
  v_actor                  users%ROWTYPE;
  v_order                  orders%ROWTYPE;
  v_payment                payments%ROWTYPE;
  v_brand                  brands%ROWTYPE;
  v_discount               order_discounts%ROWTYPE;
  v_has_discount           boolean := false;
  v_table_id               uuid;
  v_food_subtotal          decimal(15,2) := 0;
  v_alcohol_subtotal       decimal(15,2) := 0;
  v_menu_inc_total         decimal(15,2) := 0;
  v_menu_inc_cents         bigint := 0;
  v_sc_rate                decimal(5,2)  := 0;
  v_sc_pretax              decimal(15,2);
  v_sc_vat                 decimal(15,2);
  v_sc_total               decimal(15,2);
  v_is_revenue             boolean := true;
  v_payment_method_storage text := p_method;
  v_order_total            decimal(15,2) := 0;
  v_total_paid_before      decimal(15,2) := 0;
  v_total_paid_after       decimal(15,2) := 0;
  v_remaining_due          decimal(15,2) := 0;
  v_should_complete        boolean := false;
  v_vat_pricing_mode       text := 'exclusive';
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
    tax_profile jsonb NOT NULL,
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

  UPDATE public.order_items SET vat_rate=0,vat_amount=0,total_amount_ex_tax=0,paying_amount_inc_tax=0
  WHERE order_id=p_order_id AND restaurant_id=p_store_id AND status<>'cancelled'
    AND item_type='menu_item' AND is_service_item=true;

  WITH lines AS MATERIALIZED (
    SELECT oi.id,oi.menu_item_id,oi.unit_price,oi.quantity,oi.display_name,oi.label,oi.created_at,
      coalesce(mi.vat_category,'food') vat_category,
      coalesce(oi.vat_profile_snapshot,jsonb_build_array(jsonb_build_object('rate',
        CASE WHEN oi.vat_rate IN (8,10) THEN oi.vat_rate ELSE mi.effective_vat_rate END,'weight',1))) tax_profile
    FROM public.order_items oi LEFT JOIN public.menu_items mi ON mi.id=oi.menu_item_id
    WHERE oi.order_id=p_order_id AND oi.restaurant_id=p_store_id AND oi.status<>'cancelled'
      AND oi.item_type='menu_item' AND coalesce(oi.is_service_item,false)=false
  ), priced AS MATERIALIZED (
    SELECT l.*,public.direct_order_payment_vat(l.tax_profile,round(l.unit_price*l.quantity,2),v_vat_pricing_mode) tax
    FROM lines l
  ), inserted AS (
    INSERT INTO payment_discount_lines(line_id,menu_item_id,unit_price,quantity,display_name,label,
      vat_category,vat_rate,tax_profile,undiscounted_pretax,undiscounted_vat,undiscounted_inc,line_inc_cents,created_at)
    SELECT id,menu_item_id,unit_price,quantity,display_name,label,vat_category,(tax->>'vat_rate')::numeric,
      tax_profile,(tax->>'supply')::numeric,(tax->>'vat')::numeric,(tax->>'total')::numeric,
      round((tax->>'total')::numeric*100)::bigint,created_at FROM priced RETURNING line_id
  ) SELECT
    (SELECT coalesce(sum((tax->>'total')::numeric),0) FROM priced),
    (SELECT coalesce(sum(round((tax->>'total')::numeric*100)::bigint),0) FROM priced),
    coalesce(sum((part->>'total_amount_ex_tax')::numeric) FILTER(WHERE (part->>'vat_rate')::numeric=10),0),
    coalesce(sum((part->>'total_amount_ex_tax')::numeric) FILTER(WHERE (part->>'vat_rate')::numeric=8),0)
  INTO v_menu_inc_total,v_menu_inc_cents,v_alcohol_subtotal,v_food_subtotal
  FROM priced p CROSS JOIN LATERAL jsonb_array_elements(p.tax->'parts') part;


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
            - FLOOR((v_discount_cents::numeric * line_inc_cents::numeric) / v_menu_inc_cents::numeric)
      WHERE line_inc_cents > 0;

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

  -- Final targeted allocation before invoice snapshots.
  IF v_has_discount AND v_discount.approved_via = 'scheduled_promotion'
     AND EXISTS (SELECT 1 FROM public.order_discount_lines
                 WHERE order_discount_id = v_discount.id) THEN
    IF EXISTS (
      SELECT 1 FROM public.order_discount_lines allocation
      LEFT JOIN payment_discount_lines line ON line.line_id = allocation.order_item_id
      WHERE allocation.order_discount_id = v_discount.id
        AND (line.line_id IS NULL OR allocation.discount_amount < 0
          OR round(allocation.discount_amount * 100) > line.line_inc_cents)
    ) OR (SELECT round(sum(discount_amount) * 100)
          FROM public.order_discount_lines WHERE order_discount_id = v_discount.id)
         IS DISTINCT FROM v_discount_cents THEN
      RAISE EXCEPTION 'PROMOTION_ALLOCATION_MISMATCH';
    END IF;
    WITH allocations AS (
      SELECT line.line_id,coalesce(round(a.discount_amount*100)::bigint,0) cents
      FROM payment_discount_lines line LEFT JOIN public.order_discount_lines a
        ON a.order_discount_id=v_discount.id AND a.order_item_id=line.line_id
    ) UPDATE payment_discount_lines line SET allocated_discount_cents=a.cents
    FROM allocations a WHERE a.line_id=line.line_id;
  END IF;

  WITH priced AS MATERIALIZED (
    SELECT line_id,public.direct_order_payment_vat(tax_profile,round(unit_price*quantity,2),
      v_vat_pricing_mode,allocated_discount_cents::numeric/100) tax FROM payment_discount_lines
  ) UPDATE public.order_items oi SET vat_rate=(p.tax->>'vat_rate')::numeric,
    vat_amount=(p.tax->>'vat')::numeric,total_amount_ex_tax=(p.tax->>'supply')::numeric,
    paying_amount_inc_tax=(p.tax->>'total')::numeric,vat_breakdown=p.tax->'parts'
  FROM priced p WHERE oi.id=p.line_id;


  IF v_sc_rate > 0 AND v_food_subtotal > 0 THEN
    v_sc_pretax := ROUND(v_food_subtotal * v_sc_rate / 100, CASE WHEN COALESCE(NULLIF(current_setting('pos.direct_combo_snapshot',true),''),'{}')<>'{}' THEN 0 ELSE 2 END);
    v_sc_vat := ROUND(v_sc_pretax * 8 / 100, CASE WHEN COALESCE(NULLIF(current_setting('pos.direct_combo_snapshot',true),''),'{}')<>'{}' THEN 0 ELSE 2 END);
    v_sc_total := v_sc_pretax + v_sc_vat;

    IF NOT EXISTS (
      SELECT 1 FROM order_items
      WHERE order_id = p_order_id
        AND item_type = 'service_charge'
        AND display_name IN ('Service Charge (Food)','Service Charge (VAT 8%)')
    ) THEN
      INSERT INTO order_items (
        order_id, restaurant_id, item_type, display_name, menu_item_id,
        unit_price, quantity, label, status, vat_rate, vat_amount,
        total_amount_ex_tax, paying_amount_inc_tax
      )
      VALUES (
        p_order_id, p_store_id, 'service_charge', 'Service Charge (VAT 8%)', NULL,
        v_sc_pretax, 1, 'Service Charge (VAT 8%)', 'served', 8, v_sc_vat,
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
        AND display_name IN ('Service Charge (Food)','Service Charge (VAT 8%)');
    END IF;

  END IF;

  IF v_sc_rate > 0 AND v_alcohol_subtotal > 0 THEN
    v_sc_pretax := ROUND(v_alcohol_subtotal * v_sc_rate / 100, CASE WHEN COALESCE(NULLIF(current_setting('pos.direct_combo_snapshot',true),''),'{}')<>'{}' THEN 0 ELSE 2 END);
    v_sc_vat := ROUND(v_sc_pretax * 10 / 100, CASE WHEN COALESCE(NULLIF(current_setting('pos.direct_combo_snapshot',true),''),'{}')<>'{}' THEN 0 ELSE 2 END);
    v_sc_total := v_sc_pretax + v_sc_vat;

    IF NOT EXISTS (
      SELECT 1 FROM order_items
      WHERE order_id = p_order_id
        AND item_type = 'service_charge'
        AND display_name IN ('Service Charge (Alcohol)','Service Charge (VAT 10%)')
    ) THEN
      INSERT INTO order_items (
        order_id, restaurant_id, item_type, display_name, menu_item_id,
        unit_price, quantity, label, status, vat_rate, vat_amount,
        total_amount_ex_tax, paying_amount_inc_tax
      )
      VALUES (
        p_order_id, p_store_id, 'service_charge', 'Service Charge (VAT 10%)', NULL,
        v_sc_pretax, 1, 'Service Charge (VAT 10%)', 'served', 10, v_sc_vat,
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
        AND display_name IN ('Service Charge (Alcohol)','Service Charge (VAT 10%)');
    END IF;

  END IF;

  -- Never silently reprice a partly paid legacy zero-VAT charge.
  IF EXISTS (SELECT 1 FROM order_items WHERE order_id = p_order_id
             AND item_type = 'wet_tissue_charge' AND status <> 'cancelled'
             AND vat_rate IS DISTINCT FROM 8)
     AND EXISTS (SELECT 1 FROM payments WHERE order_id = p_order_id) THEN
    RAISE EXCEPTION 'WET_TISSUE_LEGACY_PAYMENT_REVIEW_REQUIRED';
  END IF;
  UPDATE order_items item
  SET vat_rate = 8,
      total_amount_ex_tax = CASE WHEN v_vat_pricing_mode = 'inclusive'
        THEN round(item.unit_price * item.quantity / 1.08, 2)
        ELSE item.unit_price * item.quantity END,
      vat_amount = CASE WHEN v_vat_pricing_mode = 'inclusive'
        THEN item.unit_price * item.quantity - round(item.unit_price * item.quantity / 1.08, 2)
        ELSE round(item.unit_price * item.quantity * .08, 2) END,
      paying_amount_inc_tax = CASE WHEN v_vat_pricing_mode = 'inclusive'
        THEN item.unit_price * item.quantity ELSE round(item.unit_price * item.quantity * 1.08, 2) END
  WHERE item.order_id = p_order_id AND item.restaurant_id = p_store_id
    AND item.item_type = 'wet_tissue_charge' AND item.status <> 'cancelled'
    AND NOT EXISTS (SELECT 1 FROM payments WHERE order_id = p_order_id);

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

    -- Lock the complete ingredient set in stable order, then consume and post
    -- one ledger row per order line / ingredient. No item -> recipe SQL loop.
    PERFORM stock.id FROM public.inventory_items stock
    JOIN (SELECT DISTINCT ingredient_id FROM public.order_choice_consumption(p_order_id,p_store_id)) ingredients ON ingredients.ingredient_id=stock.id
    WHERE stock.restaurant_id=p_store_id ORDER BY stock.id FOR UPDATE OF stock;
    WITH consumption AS MATERIALIZED (
      SELECT * FROM public.order_choice_consumption(p_order_id,p_store_id)
    ), totals AS (SELECT ingredient_id,sum(quantity) quantity FROM consumption GROUP BY ingredient_id),
    changed AS (UPDATE public.inventory_items stock SET current_stock=stock.current_stock-t.quantity,updated_at=now()
      FROM totals t WHERE stock.id=t.ingredient_id AND stock.restaurant_id=p_store_id RETURNING stock.id)
    INSERT INTO public.inventory_transactions(restaurant_id,ingredient_id,transaction_type,quantity_g,reference_type,reference_id,created_by)
    SELECT p_store_id,c.ingredient_id,'deduct',-c.quantity,'order_item',c.order_item_id,auth.uid()
    FROM consumption c;


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

CREATE OR REPLACE FUNCTION "public"."direct_order_deduct_combo_stock"("p_store_id" "uuid", "p_request_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth', 'pg_catalog'
    AS $$
DECLARE expected integer; applied integer;
BEGIN
 WITH lines AS MATERIALIZED(SELECT oi.id,oi.quantity,oi.combo_components,oi.menu_option_snapshot FROM public.direct_order_financials f
  JOIN public.order_items oi ON oi.order_id=f.order_id AND oi.restaurant_id=f.restaurant_id
  JOIN public.direct_order_request_items i ON i.request_id=f.request_id AND i.id=oi.id
  WHERE f.request_id=p_request_id AND f.restaurant_id=p_store_id AND jsonb_array_length(i.combo_components)>0),
 base_usage AS (SELECT l.id order_item_id,mr.ingredient_id,
  sum(mr.quantity_g*(c.value->>'quantity')::numeric*CASE WHEN COALESCE((c.value->>'is_total_quantity')::boolean,false) THEN 1 ELSE l.quantity END) quantity
  FROM lines l CROSS JOIN LATERAL jsonb_array_elements(l.combo_components)c
  JOIN public.menu_recipes mr ON mr.menu_item_id=(c.value->>'menu_item_id')::uuid AND mr.restaurant_id=p_store_id
  WHERE NOT l.menu_option_snapshot ? 'combo_recipe_basis'
  GROUP BY l.id,mr.ingredient_id
  UNION ALL SELECT l.id,(r->>'ingredient_id')::uuid,(l.quantity*(r->>'quantity_g')::numeric)/(l.menu_option_snapshot->'combo_recipe_basis'->>'quantity')::numeric
   FROM lines l CROSS JOIN LATERAL jsonb_array_elements(coalesce(l.menu_option_snapshot->'combo_recipe_basis'->'items','[]'))r
  UNION ALL SELECT l.id,(r->>'ingredient_id')::uuid,l.quantity*(r->>'quantity_g')::numeric
   FROM lines l CROSS JOIN LATERAL jsonb_array_elements(coalesce(l.menu_option_snapshot->'recipe_additions','[]'))r),
 consumption AS MATERIALIZED(SELECT order_item_id,ingredient_id,sum(quantity) quantity FROM base_usage GROUP BY order_item_id,ingredient_id),
 totals AS(SELECT ingredient_id,sum(quantity) quantity FROM consumption GROUP BY ingredient_id),
 changed AS(UPDATE public.inventory_items stock SET current_stock=stock.current_stock-t.quantity,updated_at=now()
  FROM totals t WHERE stock.id=t.ingredient_id AND stock.restaurant_id=p_store_id RETURNING stock.id),
 journal AS(INSERT INTO public.inventory_transactions(restaurant_id,ingredient_id,transaction_type,quantity_g,reference_type,reference_id,created_by)
  SELECT p_store_id,ingredient_id,'deduct',-quantity,'order_item',order_item_id,auth.uid() FROM consumption RETURNING ingredient_id)
 SELECT (SELECT count(*) FROM totals),(SELECT count(*) FROM changed) INTO expected,applied;
 IF expected<>applied THEN RAISE EXCEPTION 'DIRECT_ORDER_COMBO_STOCK_UNAVAILABLE'; END IF;
END $$;
CREATE OR REPLACE FUNCTION "public"."direct_order_lock_combo_stock"("p_store_id" "uuid", "p_request_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_catalog'
    AS $$
BEGIN
 PERFORM stock.id FROM public.inventory_items stock JOIN(
  SELECT DISTINCT mr.ingredient_id FROM public.menu_recipes mr JOIN(
   SELECT i.menu_item_id FROM public.direct_order_request_items i WHERE i.request_id=p_request_id AND i.restaurant_id=p_store_id
   UNION SELECT (c.value->>'menu_item_id')::uuid FROM public.direct_order_request_items i
    CROSS JOIN LATERAL jsonb_array_elements(i.combo_components)c WHERE i.request_id=p_request_id AND i.restaurant_id=p_store_id
  ) menus ON menus.menu_item_id=mr.menu_item_id WHERE mr.restaurant_id=p_store_id
 UNION SELECT (r->>'ingredient_id')::uuid FROM public.direct_order_request_items i
  CROSS JOIN LATERAL jsonb_array_elements(coalesce(i.menu_option_snapshot->'recipe_additions','[]')||coalesce(i.menu_option_snapshot->'combo_recipe_basis'->'items','[]'))r
  WHERE i.request_id=p_request_id AND i.restaurant_id=p_store_id
 ) used ON used.ingredient_id=stock.id WHERE stock.restaurant_id=p_store_id ORDER BY stock.id FOR UPDATE OF stock;
END $$;


DO $verify$ BEGIN
 IF has_function_privilege('authenticated','public.order_choice_consumption(uuid,uuid)','EXECUTE')
 OR strpos(pg_get_functiondef('public.process_payment_without_scoped_promotions(uuid,uuid,numeric,text)'::regprocedure),'order_choice_consumption')=0
 THEN RAISE EXCEPTION 'MENU_CHOICE_STOCK_CONTRACT_INVALID'; END IF;
END $verify$;
COMMIT;
