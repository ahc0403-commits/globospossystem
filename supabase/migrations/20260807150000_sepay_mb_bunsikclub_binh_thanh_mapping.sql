BEGIN;

DO $$
DECLARE
  v_store_id constant uuid := '8bc9eef5-dcd5-46b1-b931-23f77132322c'::uuid;
  v_store_name text;
  v_existing_store_id uuid;
BEGIN
  SELECT name
  INTO v_store_name
  FROM public.restaurants
  WHERE id = v_store_id;

  IF v_store_name IS DISTINCT FROM 'BunsikClub Binh Thanh' THEN
    RAISE EXCEPTION 'SEPAY_MB_STORE_MISMATCH';
  END IF;

  SELECT account.restaurant_id
  INTO v_existing_store_id
  FROM public.sepay_bank_accounts account
  WHERE lower(btrim(account.gateway)) = 'mbbank'
    AND regexp_replace(account.account_number, '[^a-zA-Z0-9]', '', 'g') =
      '5337159999'
    AND NULLIF(
      regexp_replace(COALESCE(account.sub_account, ''), '[^a-zA-Z0-9]', '', 'g'),
      ''
    ) IS NULL
  LIMIT 1;

  IF v_existing_store_id IS NOT NULL
     AND v_existing_store_id IS DISTINCT FROM v_store_id THEN
    RAISE EXCEPTION 'SEPAY_MB_ACCOUNT_ALREADY_MAPPED';
  END IF;

  INSERT INTO public.sepay_bank_accounts (
    restaurant_id,
    gateway,
    account_number,
    sub_account,
    label,
    is_active
  ) VALUES (
    v_store_id,
    'MBBank',
    '5337159999',
    NULL,
    'GLOBOS POS MB MAIN',
    true
  )
  ON CONFLICT DO NOTHING;

  UPDATE public.sepay_bank_accounts account
  SET label = 'GLOBOS POS MB MAIN',
      is_active = true,
      updated_at = now()
  WHERE account.restaurant_id = v_store_id
    AND lower(btrim(account.gateway)) = 'mbbank'
    AND regexp_replace(account.account_number, '[^a-zA-Z0-9]', '', 'g') =
      '5337159999'
    AND NULLIF(
      regexp_replace(COALESCE(account.sub_account, ''), '[^a-zA-Z0-9]', '', 'g'),
      ''
    ) IS NULL;
END
$$;

COMMIT;
