-- ============================================================
-- Inventory recommendation adjustment contract
-- 2026-05-15
--
-- Scope:
-- - POS/Admin can adjust recommendation order units before purchase order
--   creation.
-- - Office approval execution remains Office-only.
-- - Purchase order creation uses adjusted units when present.
-- ============================================================

ALTER TABLE public.inventory_recommendation_lines
  ADD COLUMN IF NOT EXISTS adjusted_order_units NUMERIC(12,3)
    CHECK (adjusted_order_units IS NULL OR adjusted_order_units >= 0),
  ADD COLUMN IF NOT EXISTS adjusted_quantity_base NUMERIC(12,3)
    CHECK (adjusted_quantity_base IS NULL OR adjusted_quantity_base >= 0),
  ADD COLUMN IF NOT EXISTS adjustment_memo TEXT,
  ADD COLUMN IF NOT EXISTS adjusted_by UUID REFERENCES auth.users(id),
  ADD COLUMN IF NOT EXISTS adjusted_at TIMESTAMPTZ;

CREATE OR REPLACE FUNCTION public.update_inventory_recommendation_line_adjustment(
  p_line_id UUID,
  p_adjusted_order_units NUMERIC,
  p_adjustment_memo TEXT DEFAULT NULL
) RETURNS public.inventory_recommendation_lines AS $$
DECLARE
  v_line public.inventory_recommendation_lines%ROWTYPE;
  v_run public.inventory_recommendation_runs%ROWTYPE;
  v_supplier_item public.inventory_supplier_items%ROWTYPE;
  v_adjusted_quantity_base NUMERIC(12,3);
BEGIN
  SELECT *
  INTO v_line
  FROM public.inventory_recommendation_lines
  WHERE id = p_line_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_RECOMMENDATION_LINE_NOT_FOUND';
  END IF;

  SELECT *
  INTO v_run
  FROM public.inventory_recommendation_runs
  WHERE id = v_line.run_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_RECOMMENDATION_RUN_NOT_FOUND';
  END IF;

  IF NOT public.can_access_inventory_purchase_store(v_run.restaurant_id) THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_FORBIDDEN';
  END IF;

  IF p_adjusted_order_units IS NULL THEN
    UPDATE public.inventory_recommendation_lines
    SET adjusted_order_units = NULL,
        adjusted_quantity_base = NULL,
        adjustment_memo = NULL,
        adjusted_by = auth.uid(),
        adjusted_at = now()
    WHERE id = p_line_id
    RETURNING * INTO v_line;

    RETURN v_line;
  END IF;

  IF p_adjusted_order_units < 0 THEN
    RAISE EXCEPTION 'INVENTORY_RECOMMENDATION_ADJUSTMENT_INVALID';
  END IF;

  IF p_adjusted_order_units > 0 THEN
    SELECT *
    INTO v_supplier_item
    FROM public.inventory_supplier_items
    WHERE product_id = v_line.product_id
      AND supplier_id = v_line.supplier_id
      AND is_active = TRUE
    ORDER BY is_preferred DESC, updated_at DESC
    LIMIT 1;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'INVENTORY_SUPPLIER_ITEM_NOT_FOUND';
    END IF;

    v_adjusted_quantity_base :=
      ROUND(p_adjusted_order_units * v_supplier_item.order_unit_quantity_base, 3);
  ELSE
    v_adjusted_quantity_base := 0;
  END IF;

  UPDATE public.inventory_recommendation_lines
  SET adjusted_order_units = p_adjusted_order_units,
      adjusted_quantity_base = v_adjusted_quantity_base,
      adjustment_memo = NULLIF(p_adjustment_memo, ''),
      adjusted_by = auth.uid(),
      adjusted_at = now()
  WHERE id = p_line_id
  RETURNING * INTO v_line;

  RETURN v_line;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

CREATE OR REPLACE FUNCTION public.create_purchase_orders_from_recommendation(
  p_run_id UUID,
  p_requested_delivery_date DATE DEFAULT NULL
) RETURNS SETOF public.inventory_purchase_orders AS $$
DECLARE
  v_run public.inventory_recommendation_runs%ROWTYPE;
  v_supplier_id UUID;
  v_order public.inventory_purchase_orders%ROWTYPE;
BEGIN
  SELECT *
  INTO v_run
  FROM public.inventory_recommendation_runs
  WHERE id = p_run_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'INVENTORY_RECOMMENDATION_RUN_NOT_FOUND';
  END IF;

  IF NOT public.can_access_inventory_purchase_store(v_run.restaurant_id) THEN
    RAISE EXCEPTION 'INVENTORY_PURCHASE_FORBIDDEN';
  END IF;

  FOR v_supplier_id IN
    SELECT DISTINCT supplier_id
    FROM public.inventory_recommendation_lines
    WHERE run_id = p_run_id
      AND supplier_id IS NOT NULL
      AND COALESCE(adjusted_order_units, recommended_order_units) > 0
  LOOP
    INSERT INTO public.inventory_purchase_orders (
      purchase_order_no,
      restaurant_id,
      brand_id,
      supplier_id,
      status,
      order_type,
      source,
      requested_delivery_date,
      submitted_by
    )
    VALUES (
      'PO-' || to_char(now(), 'YYYYMMDDHH24MISS') || '-' || upper(substr(replace(gen_random_uuid()::TEXT, '-', ''), 1, 6)),
      v_run.restaurant_id,
      v_run.brand_id,
      v_supplier_id,
      'submitted',
      'recommended',
      'pos',
      p_requested_delivery_date,
      auth.uid()
    )
    RETURNING * INTO v_order;

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
    SELECT
      v_order.id,
      adjusted.product_id,
      isi.id,
      adjusted.recommended_quantity_base,
      adjusted.effective_order_units * isi.order_unit_quantity_base,
      adjusted.effective_order_units,
      isi.order_unit,
      isi.unit_price,
      ROUND(adjusted.effective_order_units * isi.unit_price, 2),
      ROUND(adjusted.effective_order_units * isi.unit_price * COALESCE(isi.tax_rate, 0) / 100, 2),
      adjusted.adjustment_memo,
      jsonb_build_object(
        'run_id', p_run_id,
        'current_stock_base', adjusted.current_stock_base,
        'avg_daily_consumption_base', adjusted.avg_daily_consumption_base,
        'target_stock_days', adjusted.target_stock_days,
        'recommended_quantity_base', adjusted.recommended_quantity_base,
        'recommended_order_units', adjusted.recommended_order_units,
        'adjusted_quantity_base', adjusted.adjusted_quantity_base,
        'adjusted_order_units', adjusted.adjusted_order_units,
        'adjustment_memo', adjusted.adjustment_memo,
        'estimated_days_remaining', adjusted.estimated_days_remaining,
        'risk_status', adjusted.risk_status
      )
    FROM (
      SELECT
        rl.*,
        COALESCE(rl.adjusted_order_units, rl.recommended_order_units) AS effective_order_units
      FROM public.inventory_recommendation_lines rl
      WHERE rl.run_id = p_run_id
        AND rl.supplier_id = v_supplier_id
    ) adjusted
    JOIN public.inventory_supplier_items isi
      ON isi.product_id = adjusted.product_id
     AND isi.supplier_id = adjusted.supplier_id
     AND isi.is_active = TRUE
    WHERE adjusted.effective_order_units > 0;

    PERFORM public.recalculate_inventory_purchase_order_totals(v_order.id);

    SELECT *
    INTO v_order
    FROM public.inventory_purchase_orders
    WHERE id = v_order.id;

    RETURN NEXT v_order;
  END LOOP;

  RETURN;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

GRANT EXECUTE ON FUNCTION public.update_inventory_recommendation_line_adjustment(UUID, NUMERIC, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_purchase_orders_from_recommendation(UUID, DATE) TO authenticated;
