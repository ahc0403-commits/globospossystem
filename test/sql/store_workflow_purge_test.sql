-- The existing guarded purge must keep working after a baseline is captured.
-- All mutations are isolated and rolled back; no production data is used.
BEGIN;
SELECT set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000099',true);
INSERT INTO public.restaurants(id,name,slug,brand_id,tax_entity_id)
VALUES('97000000-0000-4000-8000-000000000001','Harbor Kitchen','harbor-kitchen',
 '91000000-0000-4000-8000-000000000003','91000000-0000-4000-8000-000000000004');
SELECT public.admin_capture_store_operating_baseline_v1('97000000-0000-4000-8000-000000000001',0);
INSERT INTO public.store_service_areas(id,restaurant_id,stored_code)
VALUES('97000000-0000-4000-8000-000000000002','97000000-0000-4000-8000-000000000001','1F');
INSERT INTO public.store_service_stations(id,restaurant_id,code,kind,area_id)
VALUES('97000000-0000-4000-8000-000000000003','97000000-0000-4000-8000-000000000001','legacy:floor:1F','floor','97000000-0000-4000-8000-000000000002');
INSERT INTO public.store_operating_version_stations(restaurant_id,version_id,station_id)
SELECT restaurant_id,baseline_version_id,'97000000-0000-4000-8000-000000000003'
FROM public.store_operating_profiles WHERE restaurant_id='97000000-0000-4000-8000-000000000001';
INSERT INTO public.store_operating_version_assignments(restaurant_id,version_id,station_id,user_id,legacy_assignment_id)
SELECT restaurant_id,baseline_version_id,'97000000-0000-4000-8000-000000000003',gen_random_uuid(),gen_random_uuid()
FROM public.store_operating_profiles WHERE restaurant_id='97000000-0000-4000-8000-000000000001';
INSERT INTO public.store_workflow_releases(id,restaurant_id,definition,source_hash,created_by)
VALUES('97000000-0000-4000-8000-000000000004','97000000-0000-4000-8000-000000000001','{}','fixture',auth.uid());
INSERT INTO public.store_workflow_configs(restaurant_id,active_id,candidate_id)
VALUES('97000000-0000-4000-8000-000000000001','97000000-0000-4000-8000-000000000004','97000000-0000-4000-8000-000000000004');
INSERT INTO public.store_workflow_devices(restaurant_id,user_id,device_id,release_id,pending_count)
VALUES('97000000-0000-4000-8000-000000000001',gen_random_uuid(),gen_random_uuid(),'97000000-0000-4000-8000-000000000004',0);
INSERT INTO public.orders(restaurant_id,status) VALUES('97000000-0000-4000-8000-000000000001','cancelled');
DO $$ BEGIN
 BEGIN DELETE FROM public.store_workflow_releases WHERE restaurant_id='97000000-0000-4000-8000-000000000001';
  RAISE EXCEPTION 'workflow history removed';
 EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM='OPERATING_PROFILE_IMMUTABLE'; WHEN foreign_key_violation THEN NULL; END;
 BEGIN DELETE FROM public.store_operating_version_assignments WHERE restaurant_id='97000000-0000-4000-8000-000000000001';
  RAISE EXCEPTION 'immutable deletion was allowed';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'OPERATING_PROFILE_IMMUTABLE' THEN RAISE; END IF; END;
 BEGIN UPDATE public.store_operating_versions SET source_hash=repeat('0',32) WHERE restaurant_id='97000000-0000-4000-8000-000000000001';
  RAISE EXCEPTION 'immutable update was allowed';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'OPERATING_PROFILE_IMMUTABLE' THEN RAISE; END IF; END;
 BEGIN PERFORM public.admin_purge_inactive_store('97000000-0000-4000-8000-000000000001','harbor-kitchen');
  RAISE EXCEPTION 'active store purge was allowed';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'STORE_PURGE_REQUIRES_INACTIVE' THEN RAISE; END IF; END;
END $$;
UPDATE public.restaurants SET is_active=false WHERE id='97000000-0000-4000-8000-000000000001';
INSERT INTO public.user_store_access(user_id,store_id,is_primary,is_active,source_type)
VALUES('93000000-0000-4000-8000-000000000099','97000000-0000-4000-8000-000000000001',false,true,'direct');
DO $$ BEGIN
 BEGIN PERFORM public.admin_purge_inactive_store('97000000-0000-4000-8000-000000000001','wrong-slug');
  RAISE EXCEPTION 'slug guard was bypassed';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'STORE_PURGE_CONFIRMATION_MISMATCH' THEN RAISE; END IF; END;
 BEGIN PERFORM public.admin_purge_inactive_store('97000000-0000-4000-8000-000000000001','harbor-kitchen');
  RAISE EXCEPTION 'linked account guard was bypassed';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'STORE_PURGE_HAS_ACCOUNTS' THEN RAISE; END IF; END;
END $$;
DELETE FROM public.user_store_access WHERE store_id='97000000-0000-4000-8000-000000000001';
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000001',true);
DO $$ BEGIN
 BEGIN PERFORM public.admin_purge_inactive_store('97000000-0000-4000-8000-000000000001','harbor-kitchen');
  RAISE EXCEPTION 'role guard was bypassed';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'STORE_PURGE_FORBIDDEN' THEN RAISE; END IF; END;
END $$;
SELECT set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000099',true);
SELECT public.admin_purge_inactive_store('97000000-0000-4000-8000-000000000001','harbor-kitchen');
RESET ROLE;
DO $$ BEGIN
 ASSERT NOT EXISTS(SELECT 1 FROM public.restaurants WHERE id='97000000-0000-4000-8000-000000000001');
 ASSERT NOT EXISTS(SELECT 1 FROM public.store_service_areas WHERE restaurant_id='97000000-0000-4000-8000-000000000001');
 ASSERT NOT EXISTS(SELECT 1 FROM public.store_service_stations WHERE restaurant_id='97000000-0000-4000-8000-000000000001');
 ASSERT NOT EXISTS(SELECT 1 FROM public.store_operating_profiles WHERE restaurant_id='97000000-0000-4000-8000-000000000001');
 ASSERT NOT EXISTS(SELECT 1 FROM public.store_operating_versions WHERE restaurant_id='97000000-0000-4000-8000-000000000001');
 ASSERT NOT EXISTS(SELECT 1 FROM public.store_operating_version_stations WHERE restaurant_id='97000000-0000-4000-8000-000000000001');
 ASSERT NOT EXISTS(SELECT 1 FROM public.store_operating_version_assignments WHERE restaurant_id='97000000-0000-4000-8000-000000000001');
 ASSERT EXISTS(SELECT 1 FROM public.audit_logs WHERE action='admin_purge_inactive_store'
  AND entity_id='97000000-0000-4000-8000-000000000001' AND actor_id='92000000-0000-4000-8000-000000000099');
 ASSERT (SELECT count(*)=2 FROM public.store_operating_profiles WHERE restaurant_id IN
  ('273b057e-3b69-46e3-93c1-6194c2802849','8bc9eef5-dcd5-46b1-b931-23f77132322c'));
 ASSERT NOT EXISTS(SELECT 1 FROM public.store_workflow_releases WHERE restaurant_id='97000000-0000-4000-8000-000000000001');
 ASSERT NOT EXISTS(SELECT 1 FROM public.store_workflow_devices WHERE restaurant_id='97000000-0000-4000-8000-000000000001');
 RAISE NOTICE 'WORKFLOW_GUARDED_PURGE=PASS published history, device records, versioned order, active pointer, existing guards';
END $$;
ROLLBACK;
