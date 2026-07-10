BEGIN;

-- ADR-013 closure: external-store views are POS super_admin only and must not
-- depend on view-owner privileges or broad historical grants.

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
  (
    SELECT COUNT(*)
    FROM public.users u
    WHERE u.restaurant_id = r.id
      AND u.is_active = TRUE
  ) AS active_staff,
  (
    SELECT COALESCE(SUM(p.amount), 0)
    FROM public.payments p
    WHERE p.restaurant_id = r.id
      AND p.is_revenue = TRUE
      AND p.created_at >= date_trunc('month', now())
  ) AS mtd_sales,
  (
    SELECT COUNT(DISTINCT o.id)
    FROM public.orders o
    WHERE o.restaurant_id = r.id
      AND o.created_at >= date_trunc('month', now())
  ) AS mtd_order_count
FROM public.restaurants r
LEFT JOIN public.brands b ON b.id = r.brand_id
WHERE r.store_type = 'external'
  AND public.is_super_admin();

REVOKE ALL ON public.v_external_store_sales FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.v_external_store_overview FROM PUBLIC, anon, authenticated;
GRANT SELECT ON public.v_external_store_sales TO authenticated, service_role;
GRANT SELECT ON public.v_external_store_overview TO authenticated, service_role;

COMMIT;
