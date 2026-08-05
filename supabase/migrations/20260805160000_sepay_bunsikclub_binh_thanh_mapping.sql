BEGIN;

DO $$
DECLARE
  v_store_name text;
BEGIN
  SELECT name
  INTO v_store_name
  FROM public.restaurants
  WHERE id = '8bc9eef5-dcd5-46b1-b931-23f77132322c'::uuid;

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
