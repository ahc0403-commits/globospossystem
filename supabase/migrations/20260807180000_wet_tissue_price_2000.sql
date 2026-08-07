BEGIN;

-- Preserve completed 3,000 VND lines as historical facts, but move every
-- unpaid active wet-tissue line and all future confirmations to 2,000 VND.
ALTER TABLE public.order_items
  DROP CONSTRAINT order_items_wet_tissue_charge_check;

UPDATE public.order_items item
SET unit_price = 2000,
    total_amount_ex_tax = 2000 * item.quantity,
    paying_amount_inc_tax = 2000 * item.quantity
FROM public.orders order_row
WHERE item.order_id = order_row.id
  AND item.restaurant_id = order_row.restaurant_id
  AND item.item_type = 'wet_tissue_charge'
  AND order_row.status NOT IN ('completed', 'cancelled')
  AND NOT EXISTS (
    SELECT 1
    FROM public.payments payment
    WHERE payment.order_id = item.order_id
      AND payment.restaurant_id = item.restaurant_id
  );

ALTER TABLE public.order_items
  ADD CONSTRAINT order_items_wet_tissue_charge_check
  CHECK (
    item_type <> 'wet_tissue_charge' OR (
      -- 3,000 remains valid only so completed historical rows are not rewritten.
      unit_price IN (2000, 3000)
      AND quantity BETWEEN 1 AND 100
      AND vat_rate = 0
      AND vat_amount = 0
      AND total_amount_ex_tax = unit_price * quantity
      AND paying_amount_inc_tax = unit_price * quantity
      AND COALESCE(is_service_item, false) = false
    )
  );

COMMENT ON COLUMN public.order_items.item_type IS
  'menu_item = menu line; service_charge = generated service-charge line; wet_tissue_charge = cashier-confirmed fixed 2,000 VND wet-tissue line (historical completed rows may retain 3,000 VND).';

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
    v_total := 2000 * p_quantity;

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
      0,
      0,
      v_total,
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
      vat_rate = 0,
      vat_amount = 0,
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

COMMIT;
