DO $$
DECLARE
  v_items bigint;
  v_products bigint;
  v_suppliers bigint;
  v_audits bigint;
BEGIN
  SELECT count(*)
  INTO v_items
  FROM public.inventory_items ii
  JOIN public.restaurants r ON r.id = ii.restaurant_id
  WHERE r.brand_id = '77000000-0000-0000-0000-000000000001'::uuid
    AND ii.created_at = '2026-05-06 09:00:57.334069+00'::timestamptz;

  SELECT count(*)
  INTO v_products
  FROM public.inventory_products ip
  JOIN public.restaurants r ON r.id = ip.restaurant_id
  WHERE r.brand_id = '77000000-0000-0000-0000-000000000001'::uuid
    AND ip.created_at = '2026-05-06 09:06:00.256853+00'::timestamptz;

  SELECT count(*)
  INTO v_suppliers
  FROM public.inventory_suppliers supplier
  WHERE supplier.brand_id = '77000000-0000-0000-0000-000000000001'::uuid
    AND supplier.created_at =
      '2026-05-06 09:00:57.334069+00'::timestamptz;

  SELECT count(*)
  INTO v_audits
  FROM public.inventory_stock_audit_sessions audit
  JOIN public.restaurants r ON r.id = audit.restaurant_id
  WHERE r.brand_id = '77000000-0000-0000-0000-000000000001'::uuid
    AND audit.created_at = '2026-05-06 09:00:57.334069+00'::timestamptz;

  IF v_items <> 48
     OR v_products <> 48
     OR v_suppliers <> 3
     OR v_audits <> 6 THEN
    RAISE EXCEPTION
      'PHOTO_OPS_INVENTORY_CLEANUP_PREFLIGHT_MISMATCH items=% products=% suppliers=% audits=%',
      v_items,
      v_products,
      v_suppliers,
      v_audits;
  END IF;
END;
$$;

SELECT 'Photo Ops inventory cleanup and sales-range preflight passed' AS result;
