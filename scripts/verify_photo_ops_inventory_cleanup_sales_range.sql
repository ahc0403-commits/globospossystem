DO $$
DECLARE
  v_definition text;
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.inventory_items ii
    JOIN public.restaurants r ON r.id = ii.restaurant_id
    WHERE r.brand_id = '77000000-0000-0000-0000-000000000001'::uuid
      AND ii.created_at = '2026-05-06 09:00:57.334069+00'::timestamptz
  ) OR EXISTS (
    SELECT 1
    FROM public.inventory_products ip
    JOIN public.restaurants r ON r.id = ip.restaurant_id
    WHERE r.brand_id = '77000000-0000-0000-0000-000000000001'::uuid
      AND ip.created_at = '2026-05-06 09:06:00.256853+00'::timestamptz
  ) OR EXISTS (
    SELECT 1
    FROM public.inventory_suppliers supplier
    WHERE supplier.brand_id =
      '77000000-0000-0000-0000-000000000001'::uuid
      AND supplier.created_at =
        '2026-05-06 09:00:57.334069+00'::timestamptz
  ) THEN
    RAISE EXCEPTION 'PHOTO_OPS_INVENTORY_SEED_NOT_REMOVED';
  END IF;

  IF to_regprocedure(
    'public.get_photo_ops_sales_range(date,date)'
  ) IS NULL THEN
    RAISE EXCEPTION 'PHOTO_OPS_SALES_RANGE_RPC_MISSING';
  END IF;

  SELECT pg_get_functiondef(
    'public.get_photo_ops_sales_range(date,date)'::regprocedure
  ) INTO v_definition;

  IF position('BETWEEN p_start_date AND p_end_date' IN v_definition) = 0
     OR position('user_accessible_stores' IN v_definition) = 0
     OR position('photo_objet_master' IN v_definition) = 0 THEN
    RAISE EXCEPTION 'PHOTO_OPS_SALES_RANGE_RPC_INVALID';
  END IF;

  IF has_function_privilege(
    'anon',
    'public.get_photo_ops_sales_range(date,date)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'PHOTO_OPS_SALES_RANGE_ANON_EXECUTE_NOT_REVOKED';
  END IF;

  IF NOT has_function_privilege(
    'authenticated',
    'public.get_photo_ops_sales_range(date,date)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'PHOTO_OPS_SALES_RANGE_AUTH_EXECUTE_MISSING';
  END IF;
END;
$$;

SELECT 'Photo Ops inventory cleanup and sales-range verification passed' AS result;
