DO $revenue_forecast_preflight$
BEGIN
  IF to_regclass('public.restaurants') IS NULL
     OR to_regclass('public.users') IS NULL THEN
    RAISE EXCEPTION 'REVENUE_FORECAST_PREFLIGHT_BASE_TABLES_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'restaurants'
      AND column_name = 'brand_id'
  ) THEN
    RAISE EXCEPTION 'REVENUE_FORECAST_PREFLIGHT_RESTAURANT_BRAND_MISSING';
  END IF;

  IF to_regprocedure('public.user_accessible_stores(uuid)') IS NULL THEN
    RAISE EXCEPTION 'REVENUE_FORECAST_PREFLIGHT_STORE_SCOPE_RPC_MISSING';
  END IF;

  IF to_regprocedure('auth.uid()') IS NULL THEN
    RAISE EXCEPTION 'REVENUE_FORECAST_PREFLIGHT_AUTH_UID_MISSING';
  END IF;
END;
$revenue_forecast_preflight$;
