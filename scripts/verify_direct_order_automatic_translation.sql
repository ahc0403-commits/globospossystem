BEGIN READ ONLY;
DO $verify$
BEGIN
 IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid='public.direct_order_translation_jobs'::regclass)
 OR has_table_privilege('authenticated','public.direct_order_translation_jobs','SELECT')
 OR has_function_privilege('authenticated','public.claim_direct_order_translations(integer)','EXECUTE')
 OR has_function_privilege('authenticated','public.direct_order_public_status_v7(uuid,text,uuid)','EXECUTE')
 OR NOT has_function_privilege('service_role','public.direct_order_public_status_v7(uuid,text,uuid)','EXECUTE')
 OR (SELECT provolatile FROM pg_proc WHERE oid='public.direct_order_public_status_v7(uuid,text,uuid)'::regprocedure)<>'v' THEN RAISE EXCEPTION 'TRANSLATION_PERMISSION_DRIFT'; END IF;
 IF NOT EXISTS(SELECT 1 FROM cron.job WHERE jobname='direct-order-translation-dispatch' AND schedule='10 seconds' AND active)
 OR (SELECT count(*) FROM pg_trigger WHERE NOT tgisinternal AND tgenabled='O' AND tgname IN ('direct_order_translate_message','direct_order_translate_request_note','direct_order_translate_item_note','direct_order_translate_cashier_note'))<>4 THEN RAISE EXCEPTION 'TRANSLATION_SCHEDULER_DRIFT'; END IF;
END; $verify$;
COMMIT;
