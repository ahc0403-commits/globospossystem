\set ON_ERROR_STOP on

DO $preflight$
BEGIN
  IF to_regclass('public.employee_daily_allowances') IS NULL
     OR to_regclass('public.restaurants') IS NULL
     OR to_regprocedure(
       'public.upsert_employee_daily_allowance(uuid,uuid,date,boolean,numeric,text)'
     ) IS NULL THEN
    RAISE EXCEPTION 'PHOTO_ONLY_MEAL_ALLOWANCE_DEPENDENCY_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'restaurants'
      AND column_name = 'brand_id'
      AND data_type = 'uuid'
  ) THEN
    RAISE EXCEPTION 'PHOTO_ONLY_MEAL_ALLOWANCE_BRAND_DEPENDENCY_MISSING';
  END IF;
END;
$preflight$;

SELECT 'Photo-only split-shift meal allowance preflight passed' AS result;
