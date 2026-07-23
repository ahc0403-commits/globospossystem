BEGIN;

DO $$
DECLARE
  v_item_count bigint;
  v_product_count bigint;
  v_supplier_count bigint;
  v_audit_count bigint;
BEGIN
  SELECT count(*)
  INTO v_item_count
  FROM public.inventory_items ii
  JOIN public.restaurants r ON r.id = ii.restaurant_id
  WHERE r.brand_id = '77000000-0000-0000-0000-000000000001'::uuid
    AND ii.created_at = '2026-05-06 09:00:57.334069+00'::timestamptz;

  SELECT count(*)
  INTO v_product_count
  FROM public.inventory_products ip
  JOIN public.restaurants r ON r.id = ip.restaurant_id
  WHERE r.brand_id = '77000000-0000-0000-0000-000000000001'::uuid
    AND ip.created_at = '2026-05-06 09:06:00.256853+00'::timestamptz;

  SELECT count(*)
  INTO v_supplier_count
  FROM public.inventory_suppliers supplier
  WHERE supplier.brand_id = '77000000-0000-0000-0000-000000000001'::uuid
    AND supplier.created_at =
      '2026-05-06 09:00:57.334069+00'::timestamptz;

  SELECT count(*)
  INTO v_audit_count
  FROM public.inventory_stock_audit_sessions audit
  JOIN public.restaurants r ON r.id = audit.restaurant_id
  WHERE r.brand_id = '77000000-0000-0000-0000-000000000001'::uuid
    AND audit.created_at = '2026-05-06 09:00:57.334069+00'::timestamptz;

  IF v_item_count <> 48
     OR v_product_count <> 48
     OR v_supplier_count <> 3
     OR v_audit_count <> 6 THEN
    RAISE EXCEPTION
      'PHOTO_OPS_INVENTORY_SEED_MISMATCH items=% products=% suppliers=% audits=%',
      v_item_count,
      v_product_count,
      v_supplier_count,
      v_audit_count;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.inventory_purchase_orders purchase_order
    JOIN public.restaurants r ON r.id = purchase_order.restaurant_id
    WHERE r.brand_id = '77000000-0000-0000-0000-000000000001'::uuid
  ) OR EXISTS (
    SELECT 1
    FROM public.inventory_receipts receipt
    JOIN public.restaurants r ON r.id = receipt.restaurant_id
    WHERE r.brand_id = '77000000-0000-0000-0000-000000000001'::uuid
  ) THEN
    RAISE EXCEPTION 'PHOTO_OPS_INVENTORY_HAS_OPERATIONAL_PURCHASE_DATA';
  END IF;
END;
$$;

DELETE FROM public.inventory_stock_audit_sessions audit
USING public.restaurants r
WHERE r.id = audit.restaurant_id
  AND r.brand_id = '77000000-0000-0000-0000-000000000001'::uuid
  AND audit.created_at = '2026-05-06 09:00:57.334069+00'::timestamptz;

DELETE FROM public.inventory_products product
USING public.restaurants r
WHERE r.id = product.restaurant_id
  AND r.brand_id = '77000000-0000-0000-0000-000000000001'::uuid
  AND product.created_at = '2026-05-06 09:06:00.256853+00'::timestamptz;

DELETE FROM public.inventory_items item
USING public.restaurants r
WHERE r.id = item.restaurant_id
  AND r.brand_id = '77000000-0000-0000-0000-000000000001'::uuid
  AND item.created_at = '2026-05-06 09:00:57.334069+00'::timestamptz;

DELETE FROM public.inventory_suppliers supplier
WHERE supplier.brand_id = '77000000-0000-0000-0000-000000000001'::uuid
  AND supplier.created_at = '2026-05-06 09:00:57.334069+00'::timestamptz;

CREATE OR REPLACE FUNCTION public.get_photo_ops_sales_range(
  p_start_date date,
  p_end_date date
)
RETURNS TABLE (
  store_id uuid,
  store_name text,
  sale_date date,
  total_gross_sales numeric,
  total_transactions bigint,
  total_service_amount numeric,
  active_machines bigint,
  last_pulled_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_catalog
AS $$
DECLARE
  v_role text;
BEGIN
  IF p_start_date IS NULL
     OR p_end_date IS NULL
     OR p_start_date > p_end_date THEN
    RAISE EXCEPTION 'PHOTO_OPS_SALES_RANGE_INVALID';
  END IF;

  SELECT u.role
  INTO v_role
  FROM public.users u
  WHERE u.auth_id = auth.uid()
    AND u.is_active = true
  LIMIT 1;

  IF v_role IS NULL
     OR v_role NOT IN ('photo_objet_master', 'super_admin') THEN
    RAISE EXCEPTION 'PHOTO_OPS_SALES_FORBIDDEN';
  END IF;

  RETURN QUERY
  SELECT
    s.store_id,
    r.name,
    s.sale_date,
    sum(s.gross_sales),
    sum(s.transaction_count)::bigint,
    sum(s.service_amount),
    count(DISTINCT s.device_name)::bigint,
    max(s.pulled_at)
  FROM public.photo_objet_sales s
  JOIN public.restaurants r ON r.id = s.store_id
  WHERE s.sale_date BETWEEN p_start_date AND p_end_date
    AND EXISTS (
      SELECT 1
      FROM public.user_accessible_stores(auth.uid()) access(store_id)
      WHERE access.store_id = s.store_id
    )
  GROUP BY s.store_id, r.name, s.sale_date
  ORDER BY s.sale_date DESC, r.name;
END;
$$;

REVOKE ALL ON FUNCTION public.get_photo_ops_sales_range(date, date)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_photo_ops_sales_range(date, date)
  TO authenticated, service_role;

COMMENT ON FUNCTION public.get_photo_ops_sales_range(date, date) IS
  'Returns daily Photo Objet sales within an inclusive HCM date range for the authenticated manager accessible-store scope.';

COMMIT;
