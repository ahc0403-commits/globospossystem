BEGIN READ ONLY;
DO $preflight$ BEGIN
 IF md5(pg_get_functiondef('public.process_payment(uuid,uuid,numeric,text)'::regprocedure))<>'be39d85b3e5ba56462745470db5a79db' THEN RAISE EXCEPTION 'PAYMENT_ANCHOR_DRIFT'; END IF;
 IF md5(pg_get_functiondef('public.direct_order_public_status_v3(uuid,text,uuid)'::regprocedure))<>'369f668a1c4c274d0f5f8d6dab6f6221'
 OR md5(pg_get_functiondef('public.direct_order_public_status_v5(uuid,text,uuid)'::regprocedure))<>'d992e8af09a46c4bf61caab90cf5941a' THEN RAISE EXCEPTION 'LEGACY_STATUS_CONTRACT_DRIFT'; END IF;
 IF to_regclass('public.direct_order_access_keys') IS NOT NULL OR to_regprocedure('public.direct_order_public_status_v6(uuid,text,uuid)') IS NOT NULL THEN RAISE EXCEPTION 'FINAL_AMOUNT_ALREADY_INSTALLED'; END IF;
 IF (SELECT provolatile FROM pg_proc WHERE oid='public.direct_order_public_status_v5(uuid,text,uuid)'::regprocedure)<>'v' THEN RAISE EXCEPTION 'STATUS_SESSION_ACTIVITY_MISSING'; END IF;
END; $preflight$;
COMMIT;
