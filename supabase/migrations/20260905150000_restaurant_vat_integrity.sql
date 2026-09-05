BEGIN;
-- production-gate: self-verifying
-- Future wet-tissue charges carry 8% VAT using the store pricing mode.
-- Completed/part-paid accounting history is deliberately not repriced.
ALTER TABLE public.order_items DROP CONSTRAINT order_items_wet_tissue_charge_check;
ALTER TABLE public.order_items ADD CONSTRAINT order_items_wet_tissue_charge_check
CHECK (item_type <> 'wet_tissue_charge' OR (
  unit_price IN (2000, 3000) AND quantity BETWEEN 1 AND 100
  AND vat_rate IS NOT NULL AND vat_rate = 8
  AND vat_amount IS NOT NULL AND vat_amount >= 0
  AND total_amount_ex_tax IS NOT NULL AND paying_amount_inc_tax IS NOT NULL
  AND abs(vat_amount - round(total_amount_ex_tax * .08, 2)) <= .01
  AND paying_amount_inc_tax = total_amount_ex_tax + vat_amount
  AND (total_amount_ex_tax = unit_price * quantity
       OR paying_amount_inc_tax = unit_price * quantity)
  AND COALESCE(is_service_item, false) = false
)) NOT VALID;
-- NOT VALID preserves legacy zero-VAT rows while enforcing every new write.
UPDATE public.order_items item
SET vat_rate = 8,
    total_amount_ex_tax = CASE WHEN restaurant.vat_pricing_mode = 'inclusive'
      THEN round(item.unit_price * item.quantity / 1.08, 2)
      ELSE item.unit_price * item.quantity END,
    vat_amount = CASE WHEN restaurant.vat_pricing_mode = 'inclusive'
      THEN item.unit_price * item.quantity - round(item.unit_price * item.quantity / 1.08, 2)
      ELSE round(item.unit_price * item.quantity * .08, 2) END,
    paying_amount_inc_tax = CASE WHEN restaurant.vat_pricing_mode = 'inclusive'
      THEN item.unit_price * item.quantity ELSE round(item.unit_price * item.quantity * 1.08, 2) END
FROM public.orders order_row, public.restaurants restaurant
WHERE item.order_id = order_row.id AND item.restaurant_id = restaurant.id
  AND item.item_type = 'wet_tissue_charge'
  AND order_row.status NOT IN ('completed', 'cancelled')
  AND NOT EXISTS (SELECT 1 FROM public.payments payment WHERE payment.order_id = item.order_id);

CREATE OR REPLACE FUNCTION public.set_order_wet_tissue_quantity(
  p_order_id uuid,
  p_store_id uuid,
  p_quantity integer
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
DECLARE
  v_actor public.users%ROWTYPE;
  v_order public.orders%ROWTYPE;
  v_item public.order_items%ROWTYPE;
  v_total numeric(15,2);
  v_supply numeric(15,2);
  v_vat numeric(15,2);
  v_mode text;
BEGIN
  SELECT *
  INTO v_actor
  FROM public.users
  WHERE auth_id = auth.uid()
    AND is_active = true
  LIMIT 1;

  IF NOT FOUND
     OR v_actor.role NOT IN (
       'cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin'
     ) THEN
    RAISE EXCEPTION 'WET_TISSUE_FORBIDDEN';
  END IF;

  IF p_order_id IS NULL OR p_store_id IS NULL OR p_quantity IS NULL THEN
    RAISE EXCEPTION 'WET_TISSUE_INPUT_REQUIRED';
  END IF;

  IF p_quantity < 0 OR p_quantity > 100 THEN
    RAISE EXCEPTION 'WET_TISSUE_QUANTITY_INVALID';
  END IF;

  IF NOT public.is_super_admin()
     AND NOT EXISTS (
       SELECT 1
       FROM public.user_accessible_stores(auth.uid()) scoped(store_id)
       WHERE scoped.store_id = p_store_id
     ) THEN
    RAISE EXCEPTION 'WET_TISSUE_FORBIDDEN';
  END IF;

  SELECT *
  INTO v_order
  FROM public.orders
  WHERE id = p_order_id
    AND restaurant_id = p_store_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ORDER_NOT_FOUND';
  END IF;

  IF v_order.status <> 'serving' THEN
    RAISE EXCEPTION 'ORDER_NOT_PAYABLE';
  END IF;

  IF COALESCE(v_order.order_purpose, 'customer') <> 'customer' THEN
    RAISE EXCEPTION 'WET_TISSUE_CUSTOMER_ORDER_ONLY';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.payments payment
    WHERE payment.order_id = p_order_id
      AND payment.restaurant_id = p_store_id
  ) THEN
    RAISE EXCEPTION 'WET_TISSUE_AFTER_PAYMENT';
  END IF;

  IF p_quantity = 0 THEN
    DELETE FROM public.order_items
    WHERE order_id = p_order_id
      AND restaurant_id = p_store_id
      AND item_type = 'wet_tissue_charge';
    v_total := 0;
  ELSE
    SELECT COALESCE(vat_pricing_mode, 'exclusive') INTO v_mode
    FROM public.restaurants WHERE id = p_store_id;
    v_supply := CASE WHEN v_mode = 'inclusive'
      THEN round(2000 * p_quantity / 1.08, 2) ELSE 2000 * p_quantity END;
    v_vat := CASE WHEN v_mode = 'inclusive'
      THEN 2000 * p_quantity - v_supply ELSE round(v_supply * .08, 2) END;
    v_total := v_supply + v_vat;

    INSERT INTO public.order_items (
      restaurant_id,
      order_id,
      menu_item_id,
      item_type,
      label,
      display_name,
      unit_price,
      quantity,
      status,
      vat_rate,
      vat_amount,
      total_amount_ex_tax,
      paying_amount_inc_tax,
      is_service_item
    ) VALUES (
      p_store_id,
      p_order_id,
      NULL,
      'wet_tissue_charge',
      'Khăn ướt',
      'Khăn ướt',
      2000,
      p_quantity,
      'ready',
      8,
      v_vat,
      v_supply,
      v_total,
      false
    )
    ON CONFLICT (order_id) WHERE item_type = 'wet_tissue_charge'
    DO UPDATE SET
      label = EXCLUDED.label,
      display_name = EXCLUDED.display_name,
      unit_price = EXCLUDED.unit_price,
      quantity = EXCLUDED.quantity,
      status = 'ready',
      vat_rate = 8,
      vat_amount = EXCLUDED.vat_amount,
      total_amount_ex_tax = EXCLUDED.total_amount_ex_tax,
      paying_amount_inc_tax = EXCLUDED.paying_amount_inc_tax,
      is_service_item = false
    RETURNING * INTO v_item;
  END IF;

  INSERT INTO public.audit_logs (
    actor_id,
    action,
    entity_type,
    entity_id,
    details
  ) VALUES (
    auth.uid(),
    'set_order_wet_tissue_quantity',
    'orders',
    p_order_id,
    jsonb_build_object(
      'store_id', p_store_id,
      'quantity', p_quantity,
      'unit_price', 2000,
      'total_amount', v_total
    )
  );

  RETURN jsonb_build_object(
    'order_id', p_order_id,
    'quantity', p_quantity,
    'unit_price', 2000,
    'total_amount', v_total,
    'order_item_id', v_item.id
  );
END;
$$;

REVOKE ALL ON FUNCTION public.set_order_wet_tissue_quantity(uuid, uuid, integer)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_order_wet_tissue_quantity(uuid, uuid, integer)
  TO authenticated, service_role;


-- Patch the preserved payment anchor, keeping any newer authorization wrappers.
-- Scoped promotions must reach their final allocation BEFORE order completion
-- triggers take invoice/receipt snapshots, not only afterwards in the wrapper.
DO $migration$
DECLARE
  v_rpc regprocedure := 'public.process_payment_without_scoped_promotions(uuid,uuid,numeric,text)'::regprocedure;
  v_definition text;
  v_allocation_anchor constant text := $anchor$  FOR v_item IN
    SELECT *
    FROM payment_discount_lines
    ORDER BY created_at, line_id
  LOOP$anchor$;
  v_total_anchor constant text := $anchor$  SELECT ROUND(COALESCE(SUM(COALESCE(paying_amount_inc_tax, unit_price * quantity)), 0), 2)
  INTO v_order_total$anchor$;
  v_allocations constant text := $patch$  -- Final targeted allocation before invoice snapshots.
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
    UPDATE payment_discount_lines line
    SET allocated_discount_cents = COALESCE((
      SELECT round(allocation.discount_amount * 100)::bigint
      FROM public.order_discount_lines allocation
      WHERE allocation.order_discount_id = v_discount.id
        AND allocation.order_item_id = line.line_id
    ), 0)
    WHERE line.line_id IS NOT NULL;
  END IF;

$patch$;
  v_tissues constant text := $patch$  -- Never silently reprice a partly paid legacy zero-VAT charge.
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

$patch$;
BEGIN
  SELECT pg_get_functiondef(v_rpc) INTO v_definition;
  IF (length(v_definition) - length(replace(v_definition, v_allocation_anchor, ''))) / length(v_allocation_anchor) <> 1
     OR (length(v_definition) - length(replace(v_definition, v_total_anchor, ''))) / length(v_total_anchor) <> 1 THEN
    RAISE EXCEPTION 'RESTAURANT_VAT_PAYMENT_ANCHOR_CHANGED';
  END IF;
  EXECUTE replace(replace(v_definition,
    v_allocation_anchor, v_allocations || v_allocation_anchor),
    v_total_anchor, v_tissues || v_total_anchor);
  SELECT pg_get_functiondef(v_rpc) INTO v_definition;
  IF position(v_allocations IN v_definition) = 0 OR position(v_tissues IN v_definition) = 0
     OR has_function_privilege('authenticated', v_rpc, 'EXECUTE') THEN
    RAISE EXCEPTION 'RESTAURANT_VAT_PAYMENT_VERIFICATION_FAILED';
  END IF;
END;
$migration$;

DO $verification$
BEGIN
  IF position('v_supply + v_vat' IN pg_get_functiondef(
       'public.set_order_wet_tissue_quantity(uuid,uuid,integer)'::regprocedure)) = 0
     OR NOT EXISTS (SELECT 1 FROM pg_constraint
       WHERE conrelid = 'public.order_items'::regclass
         AND conname = 'order_items_wet_tissue_charge_check' AND NOT convalidated) THEN
    RAISE EXCEPTION 'WET_TISSUE_VAT_VERIFICATION_FAILED';
  END IF;
END;
$verification$;

-- Carry the item category through the no-job export fallback as well, so the
-- client can refuse a historical zero-VAT wet-tissue row instead of hiding it.
DO $export$
DECLARE
  v_rpc regprocedure := 'public.get_restaurant_daily_sales_exports_by_tax_entity(date)'::regprocedure;
  v_definition text;
  v_anchor constant text := $anchor$'quantity', item.quantity,$anchor$;
  v_replacement constant text := $replacement$'item_type', item.item_type,
        'quantity', item.quantity,$replacement$;
BEGIN
  SELECT pg_get_functiondef(v_rpc) INTO v_definition;
  IF (length(v_definition) - length(replace(v_definition, v_anchor, ''))) / length(v_anchor) <> 1 THEN
    RAISE EXCEPTION 'RESTAURANT_VAT_EXPORT_ANCHOR_CHANGED';
  END IF;
  EXECUTE replace(v_definition, v_anchor, v_replacement);
END;
$export$;
COMMIT;
