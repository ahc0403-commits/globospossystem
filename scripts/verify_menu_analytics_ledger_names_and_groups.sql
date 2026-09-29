DO $verify$
DECLARE result jsonb; actor uuid; row_count integer;
BEGIN
  IF (SELECT count(*) FROM public.menu_categories
      WHERE name_ko IN ('음료','주류') AND analytics_group = 'drink') < 2 THEN
    RAISE EXCEPTION 'Drink category classification missing';
  END IF;
  IF (SELECT count(*) FROM public.bunsik_ledger_menu_alias(
      '8bc9eef5-dcd5-46b1-b931-23f77132322c',
      '53249604-fd2e-40f5-a776-3e1bc5f32153', '2026-08-08')) <> 1
     OR (SELECT count(*) FROM public.bunsik_ledger_menu_alias(
      '8bc9eef5-dcd5-46b1-b931-23f77132322c',
      '4eda734f-4ac9-4f05-9eeb-0a4e4b122988', '2026-09-28')) <> 1
     OR (SELECT count(*) FROM public.bunsik_ledger_menu_alias(
      '8bc9eef5-dcd5-46b1-b931-23f77132322c',
      '53249604-fd2e-40f5-a776-3e1bc5f32153', '2026-09-29')) <> 0
     OR (SELECT count(*) FROM public.bunsik_ledger_menu_alias(
      '3a268807-771f-4fd4-84fe-e1b0b00de40a',
      '53249604-fd2e-40f5-a776-3e1bc5f32153', '2026-09-15')) <> 0 THEN
    RAISE EXCEPTION 'Menu alias boundary mismatch';
  END IF;
  IF position('corrected_name' IN pg_get_functiondef(
      'public.get_paperless_operations_report(uuid,timestamptz,timestamptz)'::regprocedure
    )) = 0 THEN
    RAISE EXCEPTION 'Paperless name preservation missing';
  END IF;

  SELECT auth_id INTO actor FROM public.users
  WHERE role = 'super_admin' AND is_active = true AND auth_id IS NOT NULL
  ORDER BY id LIMIT 1;
  IF actor IS NULL THEN RAISE EXCEPTION 'No active admin for verification'; END IF;
  PERFORM set_config('request.jwt.claim.sub', actor::text, true);
  result := public.get_store_menu_sales_analytics(
    '8bc9eef5-dcd5-46b1-b931-23f77132322c',
    '2026-08-07 17:00Z','2026-09-28 17:00Z','all');
  SELECT count(*) INTO row_count FROM jsonb_array_elements(result->'menu_rows') row
  WHERE row->>'menu_key' IN (
    '53249604-fd2e-40f5-a776-3e1bc5f32153',
    '4eda734f-4ac9-4f05-9eeb-0a4e4b122988');
  IF row_count <> 0
     OR (SELECT count(*) FROM jsonb_array_elements(result->'menu_rows') row
         WHERE row->>'menu_key' = '1917ec7d-c11e-4ed6-aced-c679d2104fba'
           AND row->>'name_ko' = '코카콜라 제로'
           AND row->>'analytics_group' = 'drink') <> 1
     OR (SELECT count(*) FROM jsonb_array_elements(result->'menu_rows') row
         WHERE row->>'menu_key' = '8ce1a136-f51a-4ee6-a14e-73184a874646'
           AND row->>'name_ko' = '환타 오렌지'
           AND row->>'analytics_group' = 'drink') <> 1
     OR (SELECT sum((row->>'sold_quantity')::bigint)
         FROM jsonb_array_elements(result->'menu_rows') row)
           IS DISTINCT FROM (result #>> '{summary,sold_quantity}')::bigint
     OR (SELECT sum((row->>'menu_sales_amount')::numeric)
         FROM jsonb_array_elements(result->'menu_rows') row)
           IS DISTINCT FROM (result #>> '{summary,menu_sales_amount}')::numeric THEN
    RAISE EXCEPTION 'Production analytics correction or totals mismatch';
  END IF;
END $verify$;
