\set ON_ERROR_STOP on

BEGIN;

DO $$
DECLARE
  v_currency text;
  v_external_id uuid;
  v_restaurant_id uuid;
BEGIN
  SELECT id INTO v_restaurant_id
  FROM public.restaurants
  WHERE is_active
  ORDER BY id
  LIMIT 1;
  IF v_restaurant_id IS NULL THEN
    RAISE EXCEPTION 'VND_CURRENCY_TEST_ACTIVE_RESTAURANT_MISSING';
  END IF;

  INSERT INTO public.external_sales (
    restaurant_id,
    source_system,
    external_order_id,
    gross_amount,
    net_amount,
    order_status
  )
  VALUES (
    v_restaurant_id,
    'deliberry',
    'vnd-currency-runtime-test-20260718170000',
    0,
    0,
    'completed'
  )
  RETURNING id, currency INTO v_external_id, v_currency;
  IF v_currency <> 'VND' THEN
    RAISE EXCEPTION 'VND_CURRENCY_TEST_EXTERNAL_DEFAULT_FAILED: %', v_currency;
  END IF;

  BEGIN
    UPDATE public.external_sales
    SET currency = 'USD'
    WHERE id = v_external_id;
    RAISE EXCEPTION 'VND_CURRENCY_TEST_EXTERNAL_SALE_ACCEPTED_USD';
  EXCEPTION
    WHEN check_violation THEN NULL;
  END;
END $$;

ROLLBACK;

SELECT 'VND_CURRENCY_RUNTIME_TEST_OK' AS result;
