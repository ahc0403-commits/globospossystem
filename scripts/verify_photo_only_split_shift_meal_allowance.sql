\set ON_ERROR_STOP on

DO $verify$
BEGIN
  IF to_regprocedure(
       'public.enforce_photo_only_split_shift_meal_allowance()'
     ) IS NULL THEN
    RAISE EXCEPTION 'PHOTO_ONLY_MEAL_ALLOWANCE_GUARD_MISSING';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger
    WHERE tgrelid = 'public.employee_daily_allowances'::regclass
      AND tgname = 'trg_employee_daily_allowances_photo_meal'
      AND tgenabled <> 'D'
  ) THEN
    RAISE EXCEPTION 'PHOTO_ONLY_MEAL_ALLOWANCE_TRIGGER_MISSING';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.employee_daily_allowances allowance
    JOIN public.restaurants store ON store.id = allowance.store_id
    WHERE store.brand_id IS DISTINCT FROM
      '77000000-0000-0000-0000-000000000001'::uuid
      AND (
        allowance.is_split_shift
        OR allowance.meal_allowance_amount <> 0
      )
  ) THEN
    RAISE EXCEPTION 'NON_PHOTO_MEAL_ALLOWANCE_DATA_REMAINS';
  END IF;
END;
$verify$;

SELECT 'Photo-only split-shift meal allowance verification passed' AS result;
