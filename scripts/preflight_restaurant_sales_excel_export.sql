DO $preflight$
BEGIN
  IF to_regclass('public.restaurant_daily_sales_finalizations') IS NULL
     OR to_regclass('public.v_restaurant_sales_receipts') IS NULL
     OR to_regclass('public.restaurants') IS NULL THEN
    RAISE EXCEPTION 'RESTAURANT_SALES_EXPORT_BASE_CONTRACT_MISSING';
  END IF;

  IF to_regprocedure('public.is_super_admin()') IS NULL THEN
    RAISE EXCEPTION 'RESTAURANT_SALES_EXPORT_AUTH_HELPER_MISSING';
  END IF;
END
$preflight$;

SELECT 'RESTAURANT_SALES_EXPORT_PREFLIGHT_OK';
