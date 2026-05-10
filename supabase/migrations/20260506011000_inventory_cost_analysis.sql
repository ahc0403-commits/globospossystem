-- ============================================================
-- Inventory Cost Analysis RPC
-- 2026-05-06
--
-- Product-level consumption cost summary for the inventory purchase UI.
-- Labor and other costs stay out until their authoritative source is fixed.
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_inventory_cost_analysis(
  p_store_id UUID,
  p_from DATE DEFAULT CURRENT_DATE - 6,
  p_to DATE DEFAULT CURRENT_DATE
) RETURNS TABLE (
  product_id UUID,
  product_name TEXT,
  category TEXT,
  consumed_quantity_base NUMERIC(12,3),
  consumed_amount NUMERIC(12,2),
  avg_unit_cost NUMERIC(12,4),
  preferred_unit_cost NUMERIC(12,4),
  cost_status TEXT
) AS $$
BEGIN
  IF NOT public.can_access_inventory_purchase_store(p_store_id) THEN
    RAISE EXCEPTION 'INVENTORY_COST_ANALYSIS_FORBIDDEN';
  END IF;

  IF p_from IS NULL OR p_to IS NULL OR p_from > p_to THEN
    RAISE EXCEPTION 'INVENTORY_COST_ANALYSIS_DATE_RANGE_INVALID';
  END IF;

  RETURN QUERY
  WITH consumption AS (
    SELECT
      idc.product_id,
      SUM(idc.consumed_quantity_base)::NUMERIC(12,3) AS consumed_quantity_base,
      SUM(idc.consumed_amount)::NUMERIC(12,2) AS consumed_amount
    FROM public.inventory_daily_consumption idc
    WHERE idc.restaurant_id = p_store_id
      AND idc.consumption_date BETWEEN p_from AND p_to
    GROUP BY idc.product_id
  ),
  supplier_cost AS (
    SELECT DISTINCT ON (isi.product_id)
      isi.product_id,
      ROUND(
        isi.unit_price / NULLIF(isi.order_unit_quantity_base, 0),
        4
      ) AS preferred_unit_cost
    FROM public.inventory_supplier_items isi
    WHERE isi.is_active = TRUE
      AND isi.order_unit_quantity_base > 0
    ORDER BY isi.product_id, isi.is_preferred DESC, isi.updated_at DESC
  )
  SELECT
    ip.id AS product_id,
    ip.name AS product_name,
    COALESCE(ip.category, '-') AS category,
    COALESCE(c.consumed_quantity_base, 0)::NUMERIC(12,3),
    COALESCE(c.consumed_amount, 0)::NUMERIC(12,2),
    CASE
      WHEN COALESCE(c.consumed_quantity_base, 0) <= 0 THEN 0
      ELSE ROUND(c.consumed_amount / c.consumed_quantity_base, 4)
    END AS avg_unit_cost,
    COALESCE(sc.preferred_unit_cost, 0)::NUMERIC(12,4),
    CASE
      WHEN COALESCE(c.consumed_amount, 0) = 0 THEN 'stable'
      WHEN sc.preferred_unit_cost IS NULL THEN 'missing_supplier_cost'
      WHEN c.consumed_amount / NULLIF(c.consumed_quantity_base, 0) > sc.preferred_unit_cost * 1.1 THEN 'warning'
      ELSE 'normal'
    END AS cost_status
  FROM public.inventory_products ip
  LEFT JOIN consumption c
    ON c.product_id = ip.id
  LEFT JOIN supplier_cost sc
    ON sc.product_id = ip.id
  WHERE ip.restaurant_id = p_store_id
    AND ip.is_active = TRUE
  ORDER BY COALESCE(c.consumed_amount, 0) DESC, lower(ip.name);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public, auth;

GRANT EXECUTE ON FUNCTION public.get_inventory_cost_analysis(UUID, DATE, DATE) TO authenticated;
