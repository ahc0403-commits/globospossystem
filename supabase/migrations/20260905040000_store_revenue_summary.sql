BEGIN;

-- One statement snapshot and one row per requested store, regardless of the
-- number of payments/delivery rows. Preserve the phase-1C sales allocation basis.
CREATE OR REPLACE FUNCTION public.get_store_revenue_summary(
  p_store_ids uuid[], p_from_date date, p_to_date date
) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY INVOKER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_from timestamptz;
  v_to timestamptz;
  v_result jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'STORE_REVENUE_FORBIDDEN'; END IF;
  IF COALESCE(cardinality(p_store_ids), 0) NOT BETWEEN 1 AND 500
    OR array_ndims(p_store_ids) <> 1
    OR EXISTS (SELECT 1 FROM unnest(p_store_ids) s(id) WHERE s.id IS NULL)
    OR (SELECT count(DISTINCT s.id) FROM unnest(p_store_ids) s(id)) <> cardinality(p_store_ids)
    OR p_from_date IS NULL OR p_to_date IS NULL OR p_to_date < p_from_date
    OR NOT isfinite(p_from_date) OR NOT isfinite(p_to_date) THEN
    RAISE EXCEPTION 'STORE_REVENUE_QUERY_INVALID';
  END IF;
  IF NOT COALESCE(public.is_super_admin(), false) AND EXISTS (
    SELECT 1 FROM unnest(p_store_ids) requested(id)
    WHERE NOT EXISTS (
      SELECT 1 FROM public.user_accessible_stores(auth.uid()) allowed(id)
      WHERE allowed.id = requested.id
    )
  ) THEN RAISE EXCEPTION 'STORE_REVENUE_FORBIDDEN'; END IF;

  v_from := p_from_date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh';
  v_to := (p_to_date + 1)::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh';

  WITH contributions AS (
    SELECT p.restaurant_id AS store_id,
      CASE WHEN lower(o.sales_channel::text) = 'delivery' THEN 0::numeric
        ELSE COALESCE(p.amount_portion, p.amount, 0) END AS dine_in,
      CASE WHEN lower(o.sales_channel::text) = 'delivery'
        THEN COALESCE(p.amount_portion, p.amount, 0) ELSE 0::numeric END AS delivery
    FROM public.payments p LEFT JOIN public.orders o ON o.id = p.order_id
    WHERE p.restaurant_id = ANY(p_store_ids) AND p.is_revenue = true
      AND p.created_at >= v_from AND p.created_at < v_to
    UNION ALL
    SELECT e.restaurant_id, 0::numeric, COALESCE(e.net_amount, 0)
    FROM public.external_sales e
    WHERE e.restaurant_id = ANY(p_store_ids) AND e.is_revenue = true
      AND e.order_status = 'completed' AND e.completed_at >= v_from AND e.completed_at < v_to
    UNION ALL
    SELECT f.store_id,
      -- Clamp per store/day, before summing, as the existing Photo Objet helper does.
      greatest(COALESCE(f.total_gross_sales, 0) - COALESCE(f.total_service_amount, 0), 0),
      0::numeric
    FROM public.v_photo_objet_daily_summary f
    WHERE f.store_id = ANY(p_store_ids) AND f.sale_date >= p_from_date AND f.sale_date <= p_to_date
  ), totals AS (
    SELECT store_id, sum(dine_in) AS dine_in, sum(delivery) AS delivery
    FROM contributions GROUP BY store_id
  )
  SELECT jsonb_build_object(
    'version', 1, 'from_date', p_from_date, 'to_date', p_to_date,
    'store_count', count(*),
    'rows', jsonb_agg(jsonb_build_object(
      'store_id', requested.id, 'dine_in', COALESCE(t.dine_in, 0),
      'delivery', COALESCE(t.delivery, 0)
    ) ORDER BY requested.id)
  ) INTO v_result
  FROM unnest(p_store_ids) requested(id) LEFT JOIN totals t ON t.store_id = requested.id;
  RETURN v_result;
END;
$$;

REVOKE ALL ON FUNCTION public.get_store_revenue_summary(uuid[], date, date)
  FROM PUBLIC, anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_store_revenue_summary(uuid[], date, date) TO authenticated;
COMMENT ON FUNCTION public.get_store_revenue_summary(uuid[], date, date) IS
  'Scoped invoker sales totals for 1-500 stores in one statement snapshot. Preserves sales allocations, delivery and daily Photo Objet net sales; returns no transaction details.';
COMMIT;
