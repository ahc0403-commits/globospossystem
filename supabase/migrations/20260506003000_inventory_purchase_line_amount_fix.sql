-- ============================================================
-- Inventory Purchase Line Amount Fix
-- 2026-05-06
--
-- Line edits enter the RPC as base stock quantity, but supplier unit_price is
-- priced by order unit. Recalculate amount by converted order unit.
-- ============================================================

CREATE OR REPLACE FUNCTION public.office_update_inventory_purchase_order(
  p_purchase_order_id UUID,
  p_requested_delivery_date DATE DEFAULT NULL,
  p_memo TEXT DEFAULT NULL,
  p_office_review_comment TEXT DEFAULT NULL,
  p_lines JSONB DEFAULT '[]'::JSONB
) RETURNS public.inventory_purchase_orders AS $$
DECLARE
  v_order public.inventory_purchase_orders%ROWTYPE;
  v_line JSONB;
  v_line_id UUID;
  v_ordered_quantity_base NUMERIC(12,3);
  v_ordered_quantity_unit NUMERIC(12,3);
  v_unit_to_base_factor NUMERIC(12,6);
  v_tax_rate NUMERIC(8,6);
  v_line_memo TEXT;
  v_existing_line public.inventory_purchase_order_lines%ROWTYPE;
BEGIN
  SELECT *
  INTO v_order
  FROM public.inventory_purchase_orders
  WHERE id = p_purchase_order_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_FOUND';
  END IF;

  IF NOT public.can_office_review_inventory_purchase_store(v_order.restaurant_id) THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_OFFICE_FORBIDDEN';
  END IF;

  IF v_order.status NOT IN ('submitted', 'office_returned') THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_NOT_EDITABLE';
  END IF;

  UPDATE public.inventory_purchase_orders
  SET requested_delivery_date = COALESCE(p_requested_delivery_date, requested_delivery_date),
      memo = COALESCE(NULLIF(btrim(COALESCE(p_memo, '')), ''), memo),
      office_review_comment = COALESCE(NULLIF(btrim(COALESCE(p_office_review_comment, '')), ''), office_review_comment),
      updated_at = now()
  WHERE id = p_purchase_order_id
  RETURNING * INTO v_order;

  IF p_lines IS NOT NULL AND jsonb_typeof(p_lines) = 'array' THEN
    FOR v_line IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
      v_line_id := NULLIF(v_line->>'line_id', '')::UUID;
      v_ordered_quantity_base := NULLIF(v_line->>'ordered_quantity_base', '')::NUMERIC;
      v_line_memo := NULLIF(btrim(COALESCE(v_line->>'memo', '')), '');

      SELECT *
      INTO v_existing_line
      FROM public.inventory_purchase_order_lines
      WHERE id = v_line_id
        AND purchase_order_id = p_purchase_order_id
      FOR UPDATE;

      IF NOT FOUND THEN
        RAISE EXCEPTION 'INVENTORY_PURCHASE_LINE_NOT_FOUND';
      END IF;

      IF v_ordered_quantity_base IS NULL OR v_ordered_quantity_base < 0 THEN
        RAISE EXCEPTION 'INVENTORY_PURCHASE_LINE_QUANTITY_INVALID';
      END IF;

      v_unit_to_base_factor := CASE
        WHEN v_existing_line.ordered_quantity_unit <= 0 THEN 1
        ELSE v_existing_line.ordered_quantity_base / v_existing_line.ordered_quantity_unit
      END;
      v_ordered_quantity_unit := CASE
        WHEN v_unit_to_base_factor <= 0 THEN v_ordered_quantity_base
        ELSE ROUND(v_ordered_quantity_base / v_unit_to_base_factor, 3)
      END;
      v_tax_rate := CASE
        WHEN v_existing_line.supply_amount <= 0 THEN 0
        ELSE v_existing_line.tax_amount / v_existing_line.supply_amount
      END;

      UPDATE public.inventory_purchase_order_lines
      SET ordered_quantity_base = v_ordered_quantity_base,
          ordered_quantity_unit = v_ordered_quantity_unit,
          supply_amount = ROUND(v_ordered_quantity_unit * v_existing_line.unit_price, 2),
          tax_amount = ROUND(v_ordered_quantity_unit * v_existing_line.unit_price * v_tax_rate, 2),
          memo = COALESCE(v_line_memo, memo),
          updated_at = now()
      WHERE id = v_line_id;
    END LOOP;
  END IF;

  PERFORM public.recalculate_inventory_purchase_order_totals(p_purchase_order_id);

  SELECT *
  INTO v_order
  FROM public.inventory_purchase_orders
  WHERE id = p_purchase_order_id;

  RETURN v_order;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;
