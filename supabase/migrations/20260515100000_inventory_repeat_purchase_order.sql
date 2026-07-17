-- ============================================================
-- Inventory Repeat POS Order
-- 2026-05-15
--
-- Repeats an existing inventory purchase order inside the POS inventory
-- purchase domain. Office approval remains Office-owned.
-- ============================================================

CREATE OR REPLACE FUNCTION public.create_repeat_inventory_purchase_order(
  p_source_purchase_order_id UUID,
  p_requested_delivery_date DATE DEFAULT NULL,
  p_memo TEXT DEFAULT NULL
) RETURNS public.inventory_purchase_orders AS $$
DECLARE
  v_source public.inventory_purchase_orders%ROWTYPE;
  v_order public.inventory_purchase_orders%ROWTYPE;
  v_line public.inventory_purchase_order_lines%ROWTYPE;
  v_supplier_item public.inventory_supplier_items%ROWTYPE;
  v_line_count INTEGER := 0;
  v_ordered_quantity_unit NUMERIC(12,3);
BEGIN
  SELECT *
  INTO v_source
  FROM public.inventory_purchase_orders
  WHERE id = p_source_purchase_order_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_REPEAT_PURCHASE_SOURCE_NOT_FOUND';
  END IF;

  IF NOT public.can_access_inventory_purchase_store(v_source.restaurant_id) THEN
    RAISE EXCEPTION 'INVENTORY_REPEAT_PURCHASE_FORBIDDEN';
  END IF;

  IF v_source.supplier_id IS NULL THEN
    RAISE EXCEPTION 'INVENTORY_REPEAT_PURCHASE_SUPPLIER_REQUIRED';
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
    v_source.restaurant_id,
    v_source.brand_id,
    v_source.supplier_id,
    'submitted',
    'repeat',
    'pos',
    p_requested_delivery_date,
    auth.uid(),
    COALESCE(NULLIF(btrim(COALESCE(p_memo, '')), ''), 'Repeat from ' || v_source.purchase_order_no)
  )
  RETURNING * INTO v_order;

  FOR v_line IN
    SELECT *
    FROM public.inventory_purchase_order_lines
    WHERE purchase_order_id = v_source.id
    ORDER BY created_at, id
  LOOP
    v_ordered_quantity_unit := COALESCE(v_line.ordered_quantity_unit, 0);

    IF v_ordered_quantity_unit <= 0 THEN
      RAISE EXCEPTION 'INVENTORY_REPEAT_PURCHASE_QUANTITY_INVALID';
    END IF;

    SELECT *
    INTO v_supplier_item
    FROM public.inventory_supplier_items
    WHERE id = v_line.supplier_item_id
      AND supplier_id = v_source.supplier_id
      AND is_active = TRUE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'INVENTORY_REPEAT_PURCHASE_SUPPLIER_ITEM_NOT_FOUND';
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
      v_line.memo,
      jsonb_build_object(
        'source', 'repeat_pos',
        'source_purchase_order_id', v_source.id,
        'source_purchase_order_no', v_source.purchase_order_no,
        'source_purchase_order_line_id', v_line.id,
        'order_unit_quantity_base', v_supplier_item.order_unit_quantity_base
      )
    );

    v_line_count := v_line_count + 1;
  END LOOP;

  IF v_line_count = 0 THEN
    RAISE EXCEPTION 'INVENTORY_REPEAT_PURCHASE_LINES_REQUIRED';
  END IF;

  PERFORM public.recalculate_inventory_purchase_order_totals(v_order.id);

  SELECT *
  INTO v_order
  FROM public.inventory_purchase_orders
  WHERE id = v_order.id;

  RETURN v_order;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

GRANT EXECUTE ON FUNCTION public.create_repeat_inventory_purchase_order(UUID, DATE, TEXT) TO authenticated;
