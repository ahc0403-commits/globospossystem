BEGIN;

DO $$
DECLARE
  v_store_name text;
BEGIN
  SELECT name
  INTO v_store_name
  FROM public.restaurants
  WHERE id = '8bc9eef5-dcd5-46b1-b931-23f77132322c'::uuid;

  -- This one-store operational mapping has no subject on a new installation.
  -- Do not invent the operating store or bank identity to satisfy its guard.
  -- Any nonempty unexpected installation still fails the original name check.
  IF v_store_name IS NULL AND NOT EXISTS (SELECT 1 FROM public.restaurants) THEN
    RETURN;
  END IF;

  IF v_store_name IS DISTINCT FROM 'BunsikClub Binh Thanh' THEN
    RAISE EXCEPTION 'SEPAY_TEST_STORE_MISMATCH';
  END IF;

  INSERT INTO public.sepay_bank_accounts (
    restaurant_id,
    gateway,
    account_number,
    sub_account,
    label,
    is_active
  ) VALUES (
    '8bc9eef5-dcd5-46b1-b931-23f77132322c'::uuid,
    'Vietcombank',
    '9358674202',
    'SBSEPAYOA465N89VHYK',
    'GLOBOS POS TEST VA',
    true
  )
  ON CONFLICT DO NOTHING;
END
$$;

COMMIT;
