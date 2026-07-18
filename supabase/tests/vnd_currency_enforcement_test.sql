\set ON_ERROR_STOP on

BEGIN;

DO $$
DECLARE
  v_currency text;
  v_external_id uuid;
BEGIN
  BEGIN
    INSERT INTO ops.brands (id, name, status, currency)
    VALUES (
      '00000000-0000-0000-0000-000000000d01',
      'VND constraint rejection fixture',
      'active'::core.account_status,
      'USD'
    );
    RAISE EXCEPTION 'VND_CURRENCY_TEST_BRAND_ACCEPTED_USD';
  EXCEPTION
    WHEN check_violation THEN NULL;
  END;

  INSERT INTO ops.brands (id, name, status)
  VALUES (
    '00000000-0000-0000-0000-000000000d02',
    'VND default fixture',
    'active'::core.account_status
  )
  RETURNING currency INTO v_currency;
  IF v_currency <> 'VND' THEN
    RAISE EXCEPTION 'VND_CURRENCY_TEST_BRAND_DEFAULT_FAILED: %', v_currency;
  END IF;

  SELECT id INTO v_external_id
  FROM public.external_sales
  ORDER BY id
  LIMIT 1;
  IF v_external_id IS NOT NULL THEN
    BEGIN
      UPDATE public.external_sales
      SET currency = 'USD'
      WHERE id = v_external_id;
      RAISE EXCEPTION 'VND_CURRENCY_TEST_EXTERNAL_SALE_ACCEPTED_USD';
    EXCEPTION
      WHEN check_violation THEN NULL;
    END;
  END IF;
END $$;

ROLLBACK;

SELECT 'VND_CURRENCY_RUNTIME_TEST_OK' AS result;
