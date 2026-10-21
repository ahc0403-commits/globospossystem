\set ON_ERROR_STOP on
INSERT INTO public.restaurants(id,name) VALUES
 ('273b057e-3b69-46e3-93c1-6194c2802849','JeonGabok'),
 ('8bc9eef5-dcd5-46b1-b931-23f77132322c','BunsikClub');
INSERT INTO public.restaurant_settings VALUES
 ('273b057e-3b69-46e3-93c1-6194c2802849','paperless','kitchen_floor'),
 ('8bc9eef5-dcd5-46b1-b931-23f77132322c','paperless','kitchen_tray_floor');
INSERT INTO public.users(id,auth_id,role)
 SELECT ('e1000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,
 ('e2000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,
 CASE WHEN n=1 THEN 'super_admin' WHEN n=2 THEN 'store_admin' ELSE 'kitchen' END
 FROM generate_series(1,10)n;
INSERT INTO public.fixture_store_access VALUES('e2000000-0000-4000-8000-000000000002','8bc9eef5-dcd5-46b1-b931-23f77132322c');
INSERT INTO public.tables(restaurant_id,table_number,floor_label)
 SELECT r.id,n::text,n::text||'F' FROM public.restaurants r CROSS JOIN generate_series(1,3)n;
INSERT INTO public.emergency_station_assignments(restaurant_id,user_id,station_type,floor_label)
 SELECT '273b057e-3b69-46e3-93c1-6194c2802849',id,
 CASE WHEN n=3 THEN 'kitchen' ELSE 'floor' END,
 CASE WHEN n=4 THEN '2F' WHEN n IN (5,6) THEN '3F' END
 FROM generate_series(3,6)n JOIN public.users u ON u.id=('e1000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid;
INSERT INTO public.emergency_station_assignments(restaurant_id,user_id,station_type,floor_label)
 SELECT '8bc9eef5-dcd5-46b1-b931-23f77132322c',id,
 CASE WHEN n=7 THEN 'kitchen' WHEN n=8 THEN 'tray' ELSE 'floor' END,
 CASE WHEN n=9 THEN '1F' WHEN n=10 THEN '2F' END
 FROM generate_series(7,10)n JOIN public.users u ON u.id=('e1000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid;

CREATE TEMP TABLE operating_before AS SELECT
 (SELECT md5(jsonb_agg(to_jsonb(t) ORDER BY t.id)::text) FROM public.tables t) tables_hash,
 (SELECT md5(jsonb_agg(to_jsonb(a) ORDER BY a.id)::text) FROM public.emergency_station_assignments a) assignments_hash,
 (SELECT md5(jsonb_agg(to_jsonb(s) ORDER BY s.restaurant_id)::text) FROM public.restaurant_settings s) settings_hash;

SELECT set_config('request.jwt.claim.sub','e2000000-0000-4000-8000-000000000001',false);
DO $$ DECLARE j uuid:='273b057e-3b69-46e3-93c1-6194c2802849'; b uuid:='8bc9eef5-dcd5-46b1-b931-23f77132322c'; first jsonb; second jsonb;
BEGIN
 ASSERT (public.admin_get_store_operating_profile_v1(j)->>'revision')::int=0;
 first:=public.admin_capture_store_operating_baseline_v1(j,0);
 ASSERT first->>'runtime_authority'='legacy' AND (first->>'source_matches')::boolean;
 ASSERT first->>'workflow'='kitchen_floor';
 ASSERT jsonb_array_length(first->'stations')=3;
 ASSERT NOT EXISTS(SELECT 1 FROM jsonb_array_elements(first->'stations')s WHERE s->>'kind'='tray');
 ASSERT (SELECT jsonb_array_length(s->'user_ids')=2 FROM jsonb_array_elements(first->'stations')s WHERE s->>'stored_floor'='3F');
 second:=public.admin_capture_store_operating_baseline_v1(j,0);
 ASSERT first=second, 'idempotent capture changed identity';
 ASSERT (SELECT count(*)=1 FROM public.store_operating_versions WHERE restaurant_id=j);
 second:=public.admin_capture_store_operating_baseline_v1(b,0);
 ASSERT second->>'workflow'='kitchen_tray_floor';
 ASSERT EXISTS(SELECT 1 FROM jsonb_array_elements(second->'stations')s WHERE s->>'kind'='tray');
 ASSERT (SELECT tables_hash=(SELECT md5(jsonb_agg(to_jsonb(t) ORDER BY t.id)::text) FROM public.tables t)
  AND assignments_hash=(SELECT md5(jsonb_agg(to_jsonb(a) ORDER BY a.id)::text) FROM public.emergency_station_assignments a)
  AND settings_hash=(SELECT md5(jsonb_agg(to_jsonb(s) ORDER BY s.restaurant_id)::text) FROM public.restaurant_settings s)
  FROM operating_before), 'legacy data mutated';
 BEGIN UPDATE public.store_operating_versions SET source_hash=repeat('0',32) WHERE restaurant_id=j;
  RAISE EXCEPTION 'immutable version changed';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'OPERATING_PROFILE_IMMUTABLE' THEN RAISE; END IF; END;
 BEGIN INSERT INTO public.store_operating_version_stations(restaurant_id,version_id,station_id)
  SELECT j,(first->>'baseline_version_id')::uuid,id FROM public.store_service_stations WHERE restaurant_id=b LIMIT 1;
  RAISE EXCEPTION 'cross-store station accepted';
 EXCEPTION WHEN foreign_key_violation THEN NULL; END;
END $$;
SELECT 'OPERATING_PROFILE_LEGACY_IDENTITY=PASS';

SELECT set_config('request.jwt.claim.sub','e2000000-0000-4000-8000-000000000002',false);
SET ROLE authenticated;
DO $$ BEGIN
 PERFORM public.admin_get_store_operating_profile_v1('8bc9eef5-dcd5-46b1-b931-23f77132322c');
 BEGIN PERFORM public.admin_get_store_operating_profile_v1('273b057e-3b69-46e3-93c1-6194c2802849'); RAISE EXCEPTION 'cross store read';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'ADMIN_MUTATION_FORBIDDEN' THEN RAISE; END IF; END;
 BEGIN PERFORM public.admin_capture_store_operating_baseline_v1('273b057e-3b69-46e3-93c1-6194c2802849',1); RAISE EXCEPTION 'cross store write';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'ADMIN_MUTATION_FORBIDDEN' THEN RAISE; END IF; END;
 BEGIN PERFORM 1 FROM public.store_operating_versions; RAISE EXCEPTION 'direct table access';
 EXCEPTION WHEN insufficient_privilege THEN NULL; END;
END $$;
RESET ROLE;
SELECT 'OPERATING_PROFILE_AUTHORIZATION=PASS';

SELECT set_config('request.jwt.claim.sub','e2000000-0000-4000-8000-000000000001',false);
DO $$ DECLARE j uuid:='273b057e-3b69-46e3-93c1-6194c2802849'; original uuid; next jsonb;
BEGIN
 SELECT baseline_version_id INTO original FROM public.store_operating_profiles WHERE restaurant_id=j;
 UPDATE public.tables SET table_number='renamed-'||table_number WHERE restaurant_id=j;
 ASSERT NOT (public.admin_get_store_operating_profile_v1(j)->>'source_matches')::boolean;
 BEGIN PERFORM public.admin_capture_store_operating_baseline_v1(j,0); RAISE EXCEPTION 'stale capture accepted';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'OPERATING_PROFILE_CHANGED' THEN RAISE; END IF; END;
 next:=public.admin_capture_store_operating_baseline_v1(j,1);
 ASSERT (next->>'revision')::int=2;
 ASSERT (SELECT count(*)=2 FROM public.store_operating_versions WHERE restaurant_id=j);
 ASSERT (SELECT array_agg(station_id ORDER BY station_id) FROM public.store_operating_version_stations WHERE version_id=original)
  =(SELECT array_agg(station_id ORDER BY station_id) FROM public.store_operating_version_stations WHERE version_id=(next->>'baseline_version_id')::uuid), 'station IDs changed';
END $$;
SELECT 'OPERATING_PROFILE_DRIFT_AND_RETRY=PASS';

INSERT INTO public.tables(restaurant_id,table_number,floor_label)
 SELECT '273b057e-3b69-46e3-93c1-6194c2802849',n::text,'3F' FROM generate_series(4,2000)n;
SELECT pg_stat_statements_reset();
SELECT public.admin_capture_store_operating_baseline_v1('273b057e-3b69-46e3-93c1-6194c2802849',2) IS NOT NULL;
DO $$ BEGIN
 ASSERT (SELECT coalesce(sum(calls),0)<=2 FROM pg_stat_statements WHERE query LIKE 'WITH settings AS (%' AND query NOT LIKE '%pg_stat_statements%'), 'per-row source reads';
END $$;
SELECT calls,rows,total_exec_time FROM pg_stat_statements WHERE query LIKE 'WITH settings AS (%' AND query NOT LIKE '%pg_stat_statements%';
INSERT INTO public.tables(restaurant_id,table_number,floor_label) VALUES('273b057e-3b69-46e3-93c1-6194c2802849','overflow','3F');
DO $$ BEGIN
 BEGIN PERFORM public.admin_capture_store_operating_baseline_v1('273b057e-3b69-46e3-93c1-6194c2802849',3); RAISE EXCEPTION 'unbounded capture';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'OPERATING_PROFILE_LIMIT' THEN RAISE; END IF; END;
 ASSERT (SELECT revision=3 FROM public.store_operating_profiles WHERE restaurant_id='273b057e-3b69-46e3-93c1-6194c2802849');
END $$;
SELECT 'STORE_OPERATING_PROFILES_SQL=PASS';
