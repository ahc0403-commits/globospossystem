BEGIN READ ONLY;
SET LOCAL statement_timeout='15s';
DO $preflight$
BEGIN
 IF md5(pg_get_functiondef('public.process_payment(uuid,uuid,numeric,text)'::regprocedure))<>'be39d85b3e5ba56462745470db5a79db'
 OR to_regprocedure('public.direct_order_public_status_v9(uuid,text,uuid)') IS NULL
 OR to_regprocedure('public.direct_order_staff_detail_v5(uuid,uuid)') IS NULL
 OR to_regprocedure('public.claim_print_jobs_v2(uuid,integer)') IS NULL
 OR to_regprocedure('public.direct_order_public_status_v10(uuid,text,uuid)') IS NOT NULL
 OR EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='direct_order_requests' AND column_name='delivery_policy_version')
 THEN RAISE EXCEPTION 'POS_RELEASE_PREDECESSOR_DRIFT'; END IF;
 IF NOT EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='auth' AND table_name='users' AND column_name='is_sso_user')
 OR to_regclass('auth.users_instance_id_email_idx') IS NULL
 THEN RAISE EXCEPTION 'POS_RELEASE_AUTH_PRECONDITION_FAILED'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.restaurants WHERE id='8bc9eef5-dcd5-46b1-b931-23f77132322c' AND is_active)
 THEN RAISE EXCEPTION 'POS_RELEASE_PILOT_STORE_MISSING'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.system_config WHERE key='meinvoice_dispatch_enabled' AND value='false')
 OR EXISTS(SELECT 1 FROM public.meinvoice_jobs WHERE status='sending')
 OR EXISTS(SELECT 1 FROM cron.job WHERE active AND (jobname ILIKE '%meinvoice%' OR command ILIKE '%meinvoice-dispatcher%'))
 THEN RAISE EXCEPTION 'POS_RELEASE_MISA_QUIESCENCE_REQUIRED'; END IF;
 IF (SELECT count(*) FROM pg_trigger WHERE tgname IN ('direct_order_driver_handoff_notice','direct_order_pickup_ready_notice','direct_order_pickup_conversion_notice') AND NOT tgisinternal AND tgenabled='O')<>3
 THEN RAISE EXCEPTION 'POS_RELEASE_CUSTOMER_NOTICE_PREDECESSOR_DRIFT'; END IF;
END; $preflight$;
SELECT 'POS_RELEASE_PREFLIGHT=PASS' AS result,
 (SELECT count(*) FROM public.direct_order_requests) AS requests,
 (SELECT count(*) FROM public.payments) AS payments,
 (SELECT count(*) FROM public.red_invoice_intakes) AS buyer_records;
COMMIT;
