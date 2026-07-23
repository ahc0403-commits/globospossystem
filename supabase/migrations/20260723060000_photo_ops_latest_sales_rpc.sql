BEGIN;

CREATE OR REPLACE FUNCTION public.get_photo_ops_latest_sales()
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
  v_latest_date date;
BEGIN
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

  SELECT max(s.sale_date)
  INTO v_latest_date
  FROM public.photo_objet_sales s
  WHERE EXISTS (
    SELECT 1
    FROM public.user_accessible_stores(auth.uid()) access(store_id)
    WHERE access.store_id = s.store_id
  );

  IF v_latest_date IS NULL THEN
    RETURN;
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
  WHERE s.sale_date = v_latest_date
    AND EXISTS (
      SELECT 1
      FROM public.user_accessible_stores(auth.uid()) access(store_id)
      WHERE access.store_id = s.store_id
    )
  GROUP BY s.store_id, r.name, s.sale_date
  ORDER BY r.name;
END;
$$;

REVOKE ALL ON FUNCTION public.get_photo_ops_latest_sales()
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_photo_ops_latest_sales()
  TO authenticated, service_role;

COMMENT ON FUNCTION public.get_photo_ops_latest_sales() IS
  'Returns the latest completed Photo Objet sales date for the authenticated manager accessible-store scope.';

COMMIT;
