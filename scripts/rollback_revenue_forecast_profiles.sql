BEGIN;

DROP FUNCTION IF EXISTS public.save_revenue_forecast_profile(
  uuid,
  bigint,
  text,
  jsonb
);
DROP FUNCTION IF EXISTS public.get_revenue_forecast_profile(uuid);
DROP TABLE IF EXISTS public.revenue_forecast_profile_versions;

COMMIT;
