-- ============================================================
-- Inventory Purchase Manual POS Order
-- 2026-05-06
--
-- Manual POS inventory orders stay in the inventory purchase domain. They do
-- not use or mutate the separate Office purchase feature.
-- ============================================================

CREATE OR REPLACE FUNCTION public.create_manual_inventory_purchase_order(
  p_store_id UUID,
  p_supplier_id UUID,
  p_lines JSONB,
  p_requested_delivery_date DATE DEFAULT NULL,
  p_memo TEXT DEFAULT NULL
) RETURNS public.inventory_purchase_orders AS $$
DECLARE
  v_brand_id UUID;
  v_order public.inventory_purchase_orders%ROWTYPE;
  v_line JSONB;
  v_supplier_item public.inventory_supplier_items%ROWTYPE;
  v_ordered_quantity_unit NUMERIC(12,3);
  v_line_memo TEXT;
BEGIN
  IF NOT public.can_access_inventory_purchase_store(p_store_id) THEN
    RAISE EXCEPTION 'INVENTORY_MANUAL_PURCHASE_FORBIDDEN';
  END IF;

  IF p_supplier_id IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_MANUAL_PURCHASE_SUPPLIER_REQUIRED';
  END IF;

  IF p_lines IS NULL
     OR jsonb_typeof(p_lines) <> 'array'
     OR jsonb_array_length(p_lines) = 0 THEN
    RAISE EXCEPTION 'INVENTORY_MANUAL_PURCHASE_LINES_REQUIRED';
  END IF;

  SELECT brand_id
  INTO v_brand_id
  FROM public.restaurants
  WHERE id = p_store_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_MANUAL_PURCHASE_STORE_NOT_FOUND';
  END IF;

  INSERT INTO public.inventory_purchase_orders (
    purchase_order_no,
    restaurant_id,
    brand_id,
    supplier_id,
    status,
    order_type,
    source,
    requested_delivery_date,
    submitted_by,
    memo
  )
  VALUES (
    'PO-' || to_char(now(), 'YYYYMMDDHH24MISS') || '-' || upper(substr(replace(gen_random_uuid()::TEXT, '-', ''), 1, 6)),
    p_store_id,
    v_brand_id,
    p_supplier_id,
    'submitted',
    'manual',
    'pos',
    p_requested_delivery_date,
    auth.uid(),
    NULLIF(btrim(COALESCE(p_memo, '')), '')
  )
  RETURNING * INTO v_order;

  FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
  LOOP
    v_ordered_quantity_unit := NULLIF(v_line->>'ordered_quantity_unit', '')::NUMERIC;
    v_line_memo := NULLIF(btrim(COALESCE(v_line->>'memo', '')), '');

    IF v_ordered_quantity_unit IS NULL OR v_ordered_quantity_unit <= 0 THEN
      RAISE EXCEPTION 'INVENTORY_MANUAL_PURCHASE_QUANTITY_INVALID';
    END IF;

    SELECT *
    INTO v_supplier_item
    FROM public.inventory_supplier_items
    WHERE id = NULLIF(v_line->>'supplier_item_id', '')::UUID
      AND supplier_id = p_supplier_id
      AND is_active = TRUE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'INVENTORY_MANUAL_PURCHASE_SUPPLIER_ITEM_NOT_FOUND';
    END IF;

    v_ordered_quantity_unit := GREATEST(v_ordered_quantity_unit, v_supplier_item.min_order_quantity);

    INSERT INTO public.inventory_purchase_order_lines (
      purchase_order_id,
      product_id,
      supplier_item_id,
      recommended_quantity_base,
      ordered_quantity_base,
      ordered_quantity_unit,
      order_unit,
      unit_price,
      supply_amount,
      tax_amount,
      memo,
      recommendation_snapshot
    )
    VALUES (
      v_order.id,
      v_supplier_item.product_id,
      v_supplier_item.id,
      0,
      v_ordered_quantity_unit * v_supplier_item.order_unit_quantity_base,
      v_ordered_quantity_unit,
      v_supplier_item.order_unit,
      v_supplier_item.unit_price,
      ROUND(v_ordered_quantity_unit * v_supplier_item.unit_price, 2),
      ROUND(v_ordered_quantity_unit * v_supplier_item.unit_price * COALESCE(v_supplier_item.tax_rate, 0) / 100, 2),
      v_line_memo,
      jsonb_build_object(
        'source', 'manual_pos',
        'supplier_item_id', v_supplier_item.id,
        'order_unit_quantity_base', v_supplier_item.order_unit_quantity_base
      )
    );
  END LOOP;

  PERFORM public.recalculate_inventory_purchase_order_totals(v_order.id);

  SELECT *
  INTO v_order
  FROM public.inventory_purchase_orders
  WHERE id = v_order.id;

  RETURN v_order;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

GRANT EXECUTE ON FUNCTION public.create_manual_inventory_purchase_order(UUID, UUID, JSONB, DATE, TEXT) TO authenticated;
