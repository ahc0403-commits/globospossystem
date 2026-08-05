DO $verify$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.sepay_bank_accounts account
    JOIN public.restaurants restaurant
      ON restaurant.id = account.restaurant_id
    WHERE restaurant.id = '8bc9eef5-dcd5-46b1-b931-23f77132322c'::uuid
      AND restaurant.name = 'BunsikClub Binh Thanh'
      AND lower(btrim(account.gateway)) = 'vietcombank'
      AND regexp_replace(account.account_number, '[^a-zA-Z0-9]', '', 'g') =
        '9358674202'
      AND regexp_replace(COALESCE(account.sub_account, ''), '[^a-zA-Z0-9]', '', 'g') =
        'SBSEPAYOA465N89VHYK'
      AND account.is_active = true
  ) THEN
    RAISE EXCEPTION 'SEPAY_TEST_STORE_MAPPING_VERIFY_FAILED';
  END IF;
END;
$verify$;
