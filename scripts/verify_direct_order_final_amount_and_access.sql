BEGIN READ ONLY;
DO $verify$ BEGIN
 IF md5(pg_get_functiondef('public.process_payment(uuid,uuid,numeric,text)'::regprocedure))<>'be39d85b3e5ba56462745470db5a79db' THEN RAISE EXCEPTION 'PAYMENT_ANCHOR_DRIFT'; END IF;
 IF md5(pg_get_functiondef('public.direct_order_public_status_v3(uuid,text,uuid)'::regprocedure))<>'369f668a1c4c274d0f5f8d6dab6f6221'
 OR md5(pg_get_functiondef('public.direct_order_public_status_v5(uuid,text,uuid)'::regprocedure))<>'d992e8af09a46c4bf61caab90cf5941a' THEN RAISE EXCEPTION 'LEGACY_STATUS_CONTRACT_DRIFT'; END IF;
 IF EXISTS(SELECT 1 FROM public.direct_order_quotes WHERE status IN ('active','locked') AND amount_finalized_at IS NULL) THEN RAISE EXCEPTION 'ACTIVE_QUOTE_NOT_FINALIZED'; END IF;
 IF (SELECT provolatile FROM pg_proc WHERE oid='public.direct_order_public_status_v6(uuid,text,uuid)'::regprocedure)<>'v'
 OR has_function_privilege('anon','public.direct_order_public_status_v6(uuid,text,uuid)','EXECUTE')
 OR has_function_privilege('authenticated','public.direct_order_resolve_access(uuid,text)','EXECUTE')
 OR NOT has_function_privilege('service_role','public.direct_order_public_status_v6(uuid,text,uuid)','EXECUTE') THEN RAISE EXCEPTION 'ORDER_LINK_RPC_CONTRACT_DRIFT'; END IF;
 IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid='public.direct_order_access_keys'::regclass)
 OR has_table_privilege('authenticated','public.direct_order_access_keys','SELECT') THEN RAISE EXCEPTION 'ORDER_ACCESS_RLS_DRIFT'; END IF;
 IF (SELECT count(*) FROM pg_trigger WHERE NOT tgisinternal AND tgenabled='O' AND tgname IN ('direct_order_preserve_final_amount','direct_order_preserve_quoted_items','direct_order_revoke_finished_request','direct_order_revoke_finished_fulfillment','direct_order_revoke_refunded_pickup'))<>5 THEN RAISE EXCEPTION 'ORDER_LIFECYCLE_TRIGGER_DRIFT'; END IF;
END; $verify$;
COMMIT;
