DO $preflight$
DECLARE actual text;
BEGIN
  SELECT md5(pg_get_functiondef(
    'public.get_store_menu_sales_analytics(uuid,timestamptz,timestamptz,text)'::regprocedure
  )) INTO actual;
  IF actual <> 'f8fa60c3bfcca0ca28036287bf382695' THEN
    RAISE EXCEPTION 'Menu analytics function changed since review';
  END IF;
  SELECT md5(pg_get_functiondef(
    'public.get_paperless_operations_report_pre_meal_start(uuid,timestamptz,timestamptz)'::regprocedure
  )) INTO actual;
  IF actual <> 'a1f5ac2c4d242d48f8ece1e1ee250353' THEN
    RAISE EXCEPTION 'Paperless base function changed since review';
  END IF;
  SELECT md5(pg_get_functiondef(
    'public.get_paperless_operations_report(uuid,timestamptz,timestamptz)'::regprocedure
  )) INTO actual;
  IF actual <> '0cef3da35789b61336ba531347bedbd6' THEN
    RAISE EXCEPTION 'Paperless localization function changed since review';
  END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema='public' AND table_name='menu_categories'
               AND column_name='analytics_group') THEN
    RAISE EXCEPTION 'Category analytics group already exists';
  END IF;
  IF (SELECT count(*) FROM public.menu_items
      WHERE id IN (
        '53249604-fd2e-40f5-a776-3e1bc5f32153',
        '1917ec7d-c11e-4ed6-aced-c679d2104fba',
        '4eda734f-4ac9-4f05-9eeb-0a4e4b122988',
        '8ce1a136-f51a-4ee6-a14e-73184a874646')
      AND restaurant_id = '8bc9eef5-dcd5-46b1-b931-23f77132322c') <> 4 THEN
    RAISE EXCEPTION 'Reviewed Binh Thanh menu identity changed';
  END IF;
END $preflight$;
