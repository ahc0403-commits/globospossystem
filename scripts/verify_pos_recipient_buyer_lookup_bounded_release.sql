BEGIN READ ONLY;
SET LOCAL statement_timeout='15s';
DO $verify$
BEGIN
 IF md5(pg_get_functiondef('public.process_payment(uuid,uuid,numeric,text)'::regprocedure))<>'be39d85b3e5ba56462745470db5a79db'
 OR to_regprocedure('public.direct_order_public_status_v10(uuid,text,uuid)') IS NULL
 OR to_regprocedure('public.direct_order_public_orders_v5(uuid,text,integer)') IS NULL
 OR to_regprocedure('public.direct_order_staff_detail_v6(uuid,uuid)') IS NULL
 OR to_regprocedure('public.claim_print_jobs_v3(uuid,integer)') IS NULL
 OR to_regprocedure('public.pos_receipt_ledger_batch(date,uuid,uuid[],boolean)') IS NULL
 OR to_regprocedure('public.pos_claim_company_tax_lookup(uuid,uuid,uuid)') IS NULL
 THEN RAISE EXCEPTION 'POS_RELEASE_APPLIED_FUNCTION_DRIFT'; END IF;
 IF (SELECT count(*) FROM public.company_tax_lookup_slots)<>2
 OR (SELECT count(*) FROM public.company_tax_lookup_settings WHERE enabled)<>1
 OR NOT EXISTS(SELECT 1 FROM public.company_tax_lookup_settings WHERE store_id='8bc9eef5-dcd5-46b1-b931-23f77132322c' AND enabled)
 OR has_function_privilege('authenticated','public.pos_claim_company_tax_lookup(uuid,uuid,uuid)','EXECUTE')
 OR has_function_privilege('anon','public.pos_receipt_ledger_batch(date,uuid,uuid[],boolean)','EXECUTE')
 OR has_function_privilege('anon','public.claim_print_jobs_v3(uuid,integer)','EXECUTE')
 THEN RAISE EXCEPTION 'POS_RELEASE_SCOPE_PERMISSION_DRIFT'; END IF;
 IF strpos(pg_get_functiondef('public.claim_print_jobs(uuid,integer)'::regprocedure),'receipt_payload_version')=0
 OR strpos(pg_get_functiondef('public.claim_print_jobs_v2(uuid,integer)'::regprocedure),'receipt_payload_version')=0
 OR strpos(pg_get_functiondef('public.claim_print_jobs(uuid,integer)'::regprocedure),'request_update')=0
 OR NOT EXISTS(SELECT 1 FROM public.system_config WHERE key='meinvoice_dispatch_enabled' AND value='false')
 THEN RAISE EXCEPTION 'POS_RELEASE_COMPATIBILITY_DRIFT'; END IF;
 IF NOT EXISTS(SELECT 1 FROM storage.buckets WHERE id='direct-order-chat' AND NOT public
  AND file_size_limit=5242880 AND allowed_mime_types=ARRAY['image/jpeg','image/png','image/webp','application/pdf'])
 THEN RAISE EXCEPTION 'POS_RELEASE_ATTACHMENT_STORAGE_DRIFT'; END IF;
END; $verify$;
SELECT 'POS_RELEASE_DB_VERIFY=PASS' AS result,
 (SELECT count(*) FROM public.direct_order_requests WHERE delivery_policy_version=2) AS recipient_policy_requests,
 (SELECT count(*) FROM public.company_tax_lookup_settings WHERE enabled) AS lookup_enabled_stores;
COMMIT;
