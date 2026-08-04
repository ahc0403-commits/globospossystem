-- Keep the optional 25,000 VND split-shift meal allowance exclusive to
-- PHOTO OBJET stores. Parking allowance remains available to both brands.

UPDATE public.employee_daily_allowances allowance
SET
  is_split_shift = false,
  meal_allowance_amount = 0,
  updated_at = now()
FROM public.restaurants store
WHERE store.id = allowance.store_id
  AND store.brand_id IS DISTINCT FROM
    '77000000-0000-0000-0000-000000000001'::uuid
  AND (
    allowance.is_split_shift
    OR allowance.meal_allowance_amount <> 0
  );

CREATE OR REPLACE FUNCTION public.enforce_photo_only_split_shift_meal_allowance()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_brand_id uuid;
BEGIN
  SELECT store.brand_id
  INTO v_brand_id
  FROM public.restaurants store
  WHERE store.id = NEW.store_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'EMPLOYEE_ALLOWANCE_STORE_NOT_FOUND';
  END IF;

  IF v_brand_id IS DISTINCT FROM
       '77000000-0000-0000-0000-000000000001'::uuid
     AND (NEW.is_split_shift OR NEW.meal_allowance_amount <> 0) THEN
    RAISE EXCEPTION 'SPLIT_SHIFT_MEAL_PHOTO_ONLY';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_employee_daily_allowances_photo_meal
  ON public.employee_daily_allowances;
CREATE TRIGGER trg_employee_daily_allowances_photo_meal
BEFORE INSERT OR UPDATE OF store_id, is_split_shift, meal_allowance_amount
ON public.employee_daily_allowances
FOR EACH ROW
EXECUTE FUNCTION public.enforce_photo_only_split_shift_meal_allowance();

COMMENT ON FUNCTION public.enforce_photo_only_split_shift_meal_allowance() IS
  'Rejects split-shift meal allowances outside the PHOTO OBJET brand. The manager must explicitly select the allowance for an eligible Photo part-timer day.';
