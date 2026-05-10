BEGIN;

-- ADR-013 requires external-store data to be visible only through the
-- caller's RLS scope; invoker security prevents owner-bypass on views.
ALTER VIEW public.v_external_store_sales SET (security_invoker = true);
ALTER VIEW public.v_external_store_overview SET (security_invoker = true);
ALTER VIEW public.v_daily_revenue_by_channel SET (security_invoker = true);
ALTER VIEW public.v_settlement_summary SET (security_invoker = true);

CREATE OR REPLACE VIEW public.v_external_store_sales
WITH (security_invoker = true) AS
SELECT
  r.id AS store_id,
  r.brand_id,
  b.name AS brand_name,
  r.name AS store_name,
  DATE(p.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh') AS sale_date,
  COUNT(DISTINCT p.order_id) AS order_count,
  SUM(CASE WHEN p.is_revenue THEN p.amount ELSE 0 END) AS revenue,
  SUM(CASE WHEN NOT p.is_revenue THEN p.amount ELSE 0 END) AS service_amount
FROM public.payments p
JOIN public.restaurants r ON r.id = p.restaurant_id
LEFT JOIN public.brands b ON b.id = r.brand_id
WHERE r.store_type = 'external'
  AND public.is_super_admin()
GROUP BY r.id, r.brand_id, b.name, r.name,
         DATE(p.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh');

CREATE OR REPLACE VIEW public.v_external_store_overview
WITH (security_invoker = true) AS
SELECT
  r.id AS store_id,
  r.name AS store_name,
  b.name AS brand_name,
  r.brand_id,
  r.is_active,
  r.created_at AS registered_at,
  (SELECT COUNT(*) FROM public.users u
   WHERE u.restaurant_id = r.id AND u.is_active = TRUE) AS active_staff,
  (SELECT COALESCE(SUM(p.amount), 0)
   FROM public.payments p
   WHERE p.restaurant_id = r.id AND p.is_revenue = TRUE
     AND p.created_at >= date_trunc('month', now())) AS mtd_sales,
  (SELECT COUNT(DISTINCT o.id)
   FROM public.orders o
   WHERE o.restaurant_id = r.id
     AND o.created_at >= date_trunc('month', now())) AS mtd_order_count
FROM public.restaurants r
LEFT JOIN public.brands b ON b.id = r.brand_id
WHERE r.store_type = 'external'
  AND public.is_super_admin();

CREATE OR REPLACE VIEW public.v_daily_revenue_by_channel
WITH (security_invoker = true) AS
SELECT
  COALESCE(pos.restaurant_id, del.restaurant_id) AS restaurant_id,
  COALESCE(pos.sale_date, del.sale_date)          AS sale_date,
  COALESCE(pos.dine_in_revenue, 0)                AS dine_in_revenue,
  COALESCE(pos.dine_in_orders, 0)                 AS dine_in_orders,
  COALESCE(pos.takeaway_revenue, 0)               AS takeaway_revenue,
  COALESCE(pos.takeaway_orders, 0)                AS takeaway_orders,
  COALESCE(del.delivery_revenue, 0)               AS delivery_revenue,
  COALESCE(del.delivery_orders, 0)                AS delivery_orders,
  COALESCE(pos.dine_in_revenue, 0)
    + COALESCE(pos.takeaway_revenue, 0)
    + COALESCE(del.delivery_revenue, 0)           AS total_revenue,
  COALESCE(pos.restaurant_id, del.restaurant_id) AS store_id
FROM (
  SELECT
    o.restaurant_id,
    (p.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date AS sale_date,
    SUM(CASE WHEN o.sales_channel = 'dine_in'  THEN p.amount ELSE 0 END) AS dine_in_revenue,
    COUNT(CASE WHEN o.sales_channel = 'dine_in'  THEN 1 END)             AS dine_in_orders,
    SUM(CASE WHEN o.sales_channel = 'takeaway' THEN p.amount ELSE 0 END) AS takeaway_revenue,
    COUNT(CASE WHEN o.sales_channel = 'takeaway' THEN 1 END)             AS takeaway_orders
  FROM public.orders o
  JOIN public.payments p ON p.order_id = o.id
  WHERE o.status = 'completed' AND p.is_revenue = true
  GROUP BY o.restaurant_id, (p.created_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date
) pos
FULL OUTER JOIN (
  SELECT
    restaurant_id,
    (completed_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date AS sale_date,
    SUM(gross_amount) AS delivery_revenue,
    COUNT(*)          AS delivery_orders
  FROM public.external_sales
  WHERE is_revenue = true AND order_status = 'completed'
  GROUP BY restaurant_id, (completed_at AT TIME ZONE 'Asia/Ho_Chi_Minh')::date
) del
ON pos.restaurant_id = del.restaurant_id AND pos.sale_date = del.sale_date;

CREATE OR REPLACE VIEW public.v_settlement_summary
WITH (security_invoker = true) AS
SELECT
  ds.id,
  ds.restaurant_id,
  ds.period_label,
  ds.period_start,
  ds.period_end,
  ds.gross_total,
  ds.total_deductions,
  ds.net_settlement,
  ds.status,
  ds.received_at,
  COALESCE(
    (SELECT jsonb_agg(jsonb_build_object(
      'item_type', dsi.item_type,
      'amount', dsi.amount,
      'description', dsi.description,
      'reference_rate', dsi.reference_rate
    ) ORDER BY dsi.item_type)
    FROM public.delivery_settlement_items dsi
    WHERE dsi.settlement_id = ds.id),
    '[]'::jsonb
  ) AS items,
  (SELECT COUNT(*) FROM public.external_sales es
   WHERE es.settlement_id = ds.id AND es.is_revenue = true
  ) AS order_count,
  ds.restaurant_id AS store_id
FROM public.delivery_settlements ds;

GRANT SELECT ON public.v_external_store_sales TO authenticated;
GRANT SELECT ON public.v_external_store_overview TO authenticated;
GRANT SELECT ON public.v_daily_revenue_by_channel TO authenticated;
GRANT SELECT ON public.v_settlement_summary TO authenticated;

COMMIT;
