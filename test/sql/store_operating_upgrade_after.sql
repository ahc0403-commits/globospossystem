SELECT set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000099',false);
SELECT public.admin_capture_store_operating_baseline_v1('273b057e-3b69-46e3-93c1-6194c2802849',0) IS NOT NULL;
SELECT public.admin_capture_store_operating_baseline_v1('8bc9eef5-dcd5-46b1-b931-23f77132322c',0) IS NOT NULL;
DO $$ DECLARE row record; current_hash text; BEGIN
 ASSERT NOT EXISTS(SELECT 1 FROM operating_test.function_baseline b
  LEFT JOIN pg_proc p ON p.oid=to_regprocedure(b.signature)
  WHERE p.oid IS NULL OR md5(pg_get_functiondef(p.oid))<>b.hash), 'existing function changed during additive upgrade';
 FOR row IN SELECT * FROM operating_test.row_baseline LOOP
  EXECUTE format('SELECT md5(coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text)::text,''[]'')) FROM public.%I t',row.table_name) INTO current_hash;
  ASSERT row.hash=current_hash, 'legacy rows changed: '||row.table_name;
 END LOOP;
 ASSERT (SELECT count(*)=2 FROM public.store_operating_profiles);
 ASSERT (SELECT count(*)=2 FROM public.store_operating_versions);
 ASSERT NOT EXISTS(SELECT 1 FROM public.store_service_stations WHERE restaurant_id='273b057e-3b69-46e3-93c1-6194c2802849' AND kind='tray');
END $$;
SELECT 'OPERATING_PROFILE_CURRENT_SCHEMA_UPGRADE=PASS' AS result,
 (SELECT count(*) FROM operating_test.function_baseline) AS unchanged_functions,
 (SELECT count(*) FROM operating_test.row_baseline) AS unchanged_tables;
