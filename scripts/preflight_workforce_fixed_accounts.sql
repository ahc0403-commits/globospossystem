BEGIN;
SET TRANSACTION READ ONLY;

DO $$
DECLARE
  v_relation text;
BEGIN
  FOREACH v_relation IN ARRAY ARRAY[
    'public.brands', 'public.restaurants', 'public.users',
    'public.user_brand_access', 'public.user_store_access',
    'public.attendance_logs', 'public.inventory_transactions',
    'public.inventory_physical_counts'
  ] LOOP
    IF to_regclass(v_relation) IS NULL THEN
      RAISE EXCEPTION 'WORKFORCE_PREFLIGHT_MISSING_RELATION:%', v_relation;
    END IF;
  END LOOP;
  IF to_regprocedure('public.user_accessible_stores(uuid)') IS NULL
     OR to_regprocedure('public.require_admin_actor_for_restaurant(uuid)') IS NULL
     OR to_regprocedure('public.sync_user_store_access(uuid)') IS NULL
     OR to_regprocedure('public.refresh_user_claims(uuid)') IS NULL THEN
    RAISE EXCEPTION 'WORKFORCE_PREFLIGHT_MISSING_ACCESS_DEPENDENCY';
  END IF;
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'restaurants'
      AND column_name = 'short_code'
  ) THEN
    IF EXISTS (
      SELECT 1 FROM public.restaurants
      WHERE short_code IS NOT NULL
      GROUP BY upper(short_code) HAVING count(*) > 1
    ) THEN
      RAISE EXCEPTION 'WORKFORCE_PREFLIGHT_DUPLICATE_SHORT_CODE';
    END IF;
  END IF;
END;
$$;

COMMIT;
SELECT 'WORKFORCE_FIXED_ACCOUNTS_PREFLIGHT_OK' AS result;
