-- ============================================================
-- Inventory Consumption Refresh RPC
-- 2026-05-06
--
-- Rebuilds POS-driven daily consumption from completed orders and recipes.
-- Keeps Office purchase domains separate.
-- source = 'pos' is the only source this refresh owns.
-- ============================================================

CREATE OR REPLACE FUNCTION public.refresh_inventory_daily_consumption(
  p_store_id UUID,
  p_from DATE DEFAULT CURRENT_DATE - 6,
  p_to DATE DEFAULT CURRENT_DATE
) RETURNS INTEGER AS $$
DECLARE
  v_store public.restaurants%ROWTYPE;
  v_refreshed_count INTEGER := 0;
BEGIN
  IF NOT public.can_access_inventory_purchase_store(p_store_id) THEN
    RAISE EXCEPTION 'INVENTORY_CONSUMPTION_REFRESH_FORBIDDEN';
  END IF;

  IF p_from IS NULL OR p_to IS NULL OR p_from > p_to THEN
    RAISE EXCEPTION 'INVENTORY_CONSUMPTION_DATE_RANGE_INVALID';
  END IF;

  SELECT * INTO v_store
  FROM public.restaurants
  WHERE id = p_store_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'STORE_NOT_FOUND';
  END IF;

  WITH aggregated AS (
    SELECT
      p_store_id AS restaurant_id,
      v_store.brand_id AS brand_id,
      ip.id AS product_id,
      o.updated_at::DATE AS consumption_date,
      SUM(oi.quantity)::NUMERIC(12,3) AS sales_quantity,
      SUM(oi.quantity * mr.quantity_g)::NUMERIC(12,3) AS consumed_quantity_base,
      ROUND(
        SUM(oi.quantity * mr.quantity_g * COALESCE(ii.cost_per_unit, 0)),
        2
      ) AS consumed_amount
    FROM public.orders o
    JOIN public.order_items oi
      ON oi.order_id = o.id
     AND oi.restaurant_id = o.restaurant_id
    JOIN public.menu_recipes mr
      ON mr.menu_item_id = oi.menu_item_id
     AND mr.restaurant_id = o.restaurant_id
    JOIN public.inventory_items ii
      ON ii.id = mr.ingredient_id
     AND ii.restaurant_id = o.restaurant_id
    JOIN public.inventory_products ip
      ON ip.inventory_item_id = ii.id
     AND ip.restaurant_id = o.restaurant_id
    WHERE o.restaurant_id = p_store_id
      AND o.status = 'completed'
      AND oi.menu_item_id IS NOT NULL
      AND o.updated_at::DATE BETWEEN p_from AND p_to
    GROUP BY ip.id, o.updated_at::DATE
  ),
  upserted AS (
    INSERT INTO public.inventory_daily_consumption (
      restaurant_id,
      brand_id,
      product_id,
      consumption_date,
      sales_quantity,
      consumed_quantity_base,
      consumed_amount,
      source
    )
    SELECT
      restaurant_id,
      brand_id,
      product_id,
      consumption_date,
      sales_quantity,
      consumed_quantity_base,
      consumed_amount,
      'pos'
    FROM aggregated
    ON CONFLICT (restaurant_id, product_id, consumption_date, source)
    DO UPDATE SET
      sales_quantity = EXCLUDED.sales_quantity,
      consumed_quantity_base = EXCLUDED.consumed_quantity_base,
      consumed_amount = EXCLUDED.consumed_amount
    RETURNING id
  )
  SELECT COUNT(*) INTO v_refreshed_count
  FROM upserted;

  RETURN COALESCE(v_refreshed_count, 0);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

GRANT EXECUTE ON FUNCTION public.refresh_inventory_daily_consumption(UUID, DATE, DATE) TO authenticated;
