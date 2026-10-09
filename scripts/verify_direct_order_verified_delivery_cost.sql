BEGIN READ ONLY;
DO $verify$ BEGIN
 IF md5(pg_get_functiondef('public.process_payment(uuid,uuid,numeric,text)'::regprocedure))<>'be39d85b3e5ba56462745470db5a79db' THEN RAISE EXCEPTION 'PAYMENT_ANCHOR_DRIFT'; END IF;
 IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid='public.direct_order_delivery_cost_changes'::regclass)
 OR has_table_privilege('authenticated','public.direct_order_delivery_cost_changes','INSERT')
 OR has_function_privilege('authenticated','public.direct_order_staff_support_before_cost(uuid,uuid,integer,text,jsonb)','EXECUTE')
 OR NOT has_function_privilege('authenticated','public.direct_order_staff_support_action(uuid,uuid,integer,text,jsonb)','EXECUTE') THEN RAISE EXCEPTION 'VERIFIED_DELIVERY_PERMISSIONS_DRIFT'; END IF;
 IF (SELECT count(*) FROM pg_trigger WHERE NOT tgisinternal AND tgenabled='O' AND tgname IN ('direct_order_delivery_cost_immutable','zz_direct_order_verify_dispatch_cost'))<>2 THEN RAISE EXCEPTION 'VERIFIED_DELIVERY_TRIGGER_DRIFT'; END IF;
 IF strpos(pg_get_functiondef('public.direct_order_staff_support_action(uuid,uuid,integer,text,jsonb)'::regprocedure),'DIRECT_ORDER_DELIVERY_EVIDENCE_REQUIRED')=0 THEN RAISE EXCEPTION 'VERIFIED_DELIVERY_EVIDENCE_GUARD_MISSING'; END IF;
END; $verify$;
COMMIT;
