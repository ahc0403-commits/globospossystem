DO $verify$
DECLARE result jsonb; actor uuid;
BEGIN
  SELECT auth_id INTO actor FROM public.users
  WHERE role='super_admin' AND is_active=true AND auth_id IS NOT NULL
  ORDER BY id LIMIT 1;
  IF actor IS NULL THEN RAISE EXCEPTION 'No active admin for verification'; END IF;
  PERFORM set_config('request.jwt.claim.sub', actor::text, true);
  result := public.get_paperless_operations_insights_report(
    '8bc9eef5-dcd5-46b1-b931-23f77132322c',
    '2026-08-07 17:00Z','2026-09-28 17:00Z');
  IF (SELECT count(*) FROM jsonb_array_elements(result->'menu_operation_times') row
      WHERE row->>'menu_key' IN (
        '53249604-fd2e-40f5-a776-3e1bc5f32153',
        '4eda734f-4ac9-4f05-9eeb-0a4e4b122988')) <> 0
     OR (SELECT count(*) FROM jsonb_array_elements(result->'menu_operation_times') row
         WHERE row->>'menu_key' = '1917ec7d-c11e-4ed6-aced-c679d2104fba'
           AND row->>'name_ko' = '코카콜라 제로'
           AND row->>'corrected_name' = 'true') <> 1
     OR (SELECT count(*) FROM jsonb_array_elements(result->'menu_operation_times') row
         WHERE row->>'menu_key' = '8ce1a136-f51a-4ee6-a14e-73184a874646'
           AND row->>'name_ko' = '환타 오렌지'
           AND row->>'corrected_name' = 'true') <> 1
     OR (SELECT sum((row->>'sample_count')::bigint)
         FROM jsonb_array_elements(result->'menu_operation_times') row) <> 12251 THEN
    RAISE EXCEPTION 'Paperless operation labels or sample totals mismatch';
  END IF;

  IF (public.get_paperless_menu_timing_detail(
        '8bc9eef5-dcd5-46b1-b931-23f77132322c',
        '2026-08-07 17:00Z','2026-09-28 17:00Z',
        '1917ec7d-c11e-4ed6-aced-c679d2104fba',NULL,1,NULL,NULL)
      ->>'total_count')::integer <> 1309
     OR (public.get_paperless_menu_timing_detail(
        '8bc9eef5-dcd5-46b1-b931-23f77132322c',
        '2026-08-07 17:00Z','2026-09-28 17:00Z',
        '8ce1a136-f51a-4ee6-a14e-73184a874646',NULL,1,NULL,NULL)
      ->>'total_count')::integer <> 550
     OR (public.get_paperless_menu_timing_detail(
        '8bc9eef5-dcd5-46b1-b931-23f77132322c',
        '2026-08-07 17:00Z','2026-09-28 17:00Z',
        '53249604-fd2e-40f5-a776-3e1bc5f32153',NULL,1,NULL,NULL)
      ->>'total_count')::integer <> 0
     OR (public.get_paperless_menu_timing_detail(
        '8bc9eef5-dcd5-46b1-b931-23f77132322c',
        '2026-08-07 17:00Z','2026-09-28 17:00Z',
        '4eda734f-4ac9-4f05-9eeb-0a4e4b122988',NULL,1,NULL,NULL)
      ->>'total_count')::integer <> 0 THEN
    RAISE EXCEPTION 'Paperless detail does not match corrected summary';
  END IF;
END $verify$;
