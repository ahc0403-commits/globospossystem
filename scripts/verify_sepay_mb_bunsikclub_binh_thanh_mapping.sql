DO $$
DECLARE
  v_mapping_count integer;
BEGIN
  SELECT count(*)
  INTO v_mapping_count
  FROM public.sepay_bank_accounts account
  JOIN public.restaurants restaurant ON restaurant.id = account.restaurant_id
  WHERE restaurant.id = '8bc9eef5-dcd5-46b1-b931-23f77132322c'::uuid
    AND restaurant.name = 'BunsikClub Binh Thanh'
    AND lower(btrim(account.gateway)) = 'mbbank'
    AND regexp_replace(account.account_number, '[^a-zA-Z0-9]', '', 'g') =
      '5337159999'
    AND NULLIF(
      regexp_replace(COALESCE(account.sub_account, ''), '[^a-zA-Z0-9]', '', 'g'),
      ''
    ) IS NULL
    AND account.is_active = true;

  IF v_mapping_count <> 1 THEN
    RAISE EXCEPTION 'SEPAY_MB_MAPPING_VERIFY_FAILED';
  END IF;
END
$$;
