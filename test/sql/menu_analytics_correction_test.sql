BEGIN;
SELECT set_config('request.jwt.claim.sub','b1000000-0000-4000-8000-0000000000a1',true);
DO $test$
DECLARE result jsonb; category public.menu_categories%ROWTYPE;
BEGIN
  category := public.admin_create_menu_category_with_group(
    '8bc9eef5-dcd5-46b1-b931-23f77132322c',
    '차','Trà','Tea',9,'drink');
  IF category.analytics_group <> 'drink' THEN
    RAISE EXCEPTION 'New drink category lost classification';
  END IF;
  category := public.admin_update_menu_category_with_group(
    category.id,'식사','Bữa ăn','Meals','food');
  IF category.analytics_group <> 'food' THEN
    RAISE EXCEPTION 'Edited category lost classification';
  END IF;
  IF (SELECT analytics_group FROM public.menu_categories
      WHERE id = 'f4a29074-33b8-4b46-9055-5b37b9d11650') <> 'drink' THEN
    RAISE EXCEPTION 'Drink category seed missing';
  END IF;
  IF (SELECT count(*) FROM public.bunsik_ledger_menu_alias(
      'b1000000-0000-4000-8000-000000000005',
      '53249604-fd2e-40f5-a776-3e1bc5f32153','2026-09-15')) <> 0
     OR (SELECT count(*) FROM public.bunsik_ledger_menu_alias(
      '8bc9eef5-dcd5-46b1-b931-23f77132322c',
      '53249604-fd2e-40f5-a776-3e1bc5f32153','2026-09-29')) <> 0 THEN
    RAISE EXCEPTION 'Correction escaped store or date scope';
  END IF;
  result := public.get_store_menu_sales_analytics(
    '8bc9eef5-dcd5-46b1-b931-23f77132322c',
    '2026-09-14 17:00Z','2026-09-15 17:00Z','all');
  IF (result #>> '{summary,sold_quantity}')::integer <> 5
     OR (result #>> '{summary,menu_sales_amount}')::numeric <> 57000
     OR jsonb_array_length(result->'menu_rows') <> 2
     OR (SELECT count(*) FROM jsonb_array_elements(result->'menu_rows') row
         WHERE row->>'menu_key' IN (
           '53249604-fd2e-40f5-a776-3e1bc5f32153',
           '4eda734f-4ac9-4f05-9eeb-0a4e4b122988')) <> 0
     OR (SELECT count(*) FROM jsonb_array_elements(result->'menu_rows') row
         WHERE row->>'analytics_group' = 'drink') <> 2
     OR (SELECT row->>'name_ko' FROM jsonb_array_elements(result->'menu_rows') row
         WHERE row->>'menu_key' = '1917ec7d-c11e-4ed6-aced-c679d2104fba') <> '코카콜라 제로'
     OR (SELECT row->>'display_name' FROM jsonb_array_elements(result->'menu_rows') row
         WHERE row->>'menu_key' = '1917ec7d-c11e-4ed6-aced-c679d2104fba') <> '코카콜라 제로'
     OR (SELECT row->>'name_ko' FROM jsonb_array_elements(result->'menu_rows') row
         WHERE row->>'menu_key' = '8ce1a136-f51a-4ee6-a14e-73184a874646') <> '환타 오렌지' THEN
    RAISE EXCEPTION 'Corrected menu analytics mismatch: %', result;
  END IF;
  result := public.get_paperless_operations_report(
    '8bc9eef5-dcd5-46b1-b931-23f77132322c',
    '2026-09-14 17:00Z','2026-09-15 17:00Z');
  IF jsonb_array_length(result->'menu_operation_times') <> 2
     OR (SELECT count(*) FROM jsonb_array_elements(result->'menu_operation_times') row
         WHERE row->>'menu_key' = '1917ec7d-c11e-4ed6-aced-c679d2104fba'
           AND row->>'name_ko' = '코카콜라 제로'
           AND row->>'name_en' = 'Coca-Cola Zero'
           AND (row->>'sample_count')::integer = 2) <> 1
     OR (SELECT count(*) FROM jsonb_array_elements(result->'menu_operation_times') row
         WHERE row->>'menu_key' = '8ce1a136-f51a-4ee6-a14e-73184a874646'
           AND row->>'name_ko' = '환타 오렌지'
           AND row->>'name_vi' = 'Fanta Cam') <> 1
     OR result #>> '{menu_kitchen_times,0,name}' <> '코카콜라 제로' THEN
    RAISE EXCEPTION 'Paperless menu timing correction mismatch: %', result;
  END IF;
  result := public.get_store_menu_sales_analytics(
    '8bc9eef5-dcd5-46b1-b931-23f77132322c',
    '2026-09-28 17:00Z','2026-09-29 17:00Z','all');
  IF result #>> '{menu_rows,0,menu_key}' <> '53249604-fd2e-40f5-a776-3e1bc5f32153'
     OR result #>> '{menu_rows,0,display_name}' <> '코카콜라 일반' THEN
    RAISE EXCEPTION 'Outside-period menu identity changed: %', result;
  END IF;
END $test$;
ROLLBACK;
