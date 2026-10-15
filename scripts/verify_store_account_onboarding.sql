SET LOCAL transaction_read_only=on;
DO $$
BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_class WHERE oid='public.restaurants'::regclass AND relkind='r') THEN RAISE EXCEPTION 'OFFICE_PHYSICAL_STORE_CONTRACT_CHANGED'; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_class WHERE oid='public.store_account_onboarding_jobs'::regclass AND relrowsecurity) THEN RAISE EXCEPTION 'ONBOARDING_RLS_MISSING'; END IF;
 IF has_function_privilege('authenticated','public.claim_store_onboarding_v1(uuid)','EXECUTE') OR has_function_privilege('anon','public.admin_create_store_onboarding_v1(uuid,text,text,text,uuid,uuid,text[],text,numeric)','EXECUTE') THEN RAISE EXCEPTION 'ONBOARDING_WORKER_EXPOSED'; END IF;
 IF NOT has_function_privilege('service_role','public.finish_store_onboarding_v1(uuid,uuid)','EXECUTE') THEN RAISE EXCEPTION 'ONBOARDING_WORKER_INACCESSIBLE'; END IF;
 IF NOT EXISTS(SELECT 1 FROM cron.job WHERE jobname='store-account-onboarding' AND active) THEN RAISE EXCEPTION 'ONBOARDING_DURABLE_RETRY_MISSING'; END IF;
 IF EXISTS(SELECT 1 FROM pg_constraint WHERE contype='c' AND conrelid IN ('public.emergency_station_assignments'::regclass,'public.emergency_order_queue'::regclass,'public.kds_shadow_health'::regclass,'public.kds_change_log'::regclass,'public.emergency_tray_floor_batch_actions'::regclass) AND pg_get_constraintdef(oid) LIKE '%1F%' AND pg_get_constraintdef(oid) LIKE '%2F%' AND pg_get_constraintdef(oid) NOT LIKE '%3F%') THEN RAISE EXCEPTION 'THIRD_FLOOR_CONSTRAINT_MISSING'; END IF;
END $$;
SELECT 'ONBOARDING_VERIFY_PASS' AS result;
