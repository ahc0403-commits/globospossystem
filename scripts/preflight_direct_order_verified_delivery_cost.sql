BEGIN READ ONLY;
DO $preflight$ BEGIN
 IF md5(pg_get_functiondef('public.process_payment(uuid,uuid,numeric,text)'::regprocedure))<>'be39d85b3e5ba56462745470db5a79db' THEN RAISE EXCEPTION 'PAYMENT_ANCHOR_DRIFT'; END IF;
 IF to_regprocedure('public.direct_order_public_status_v6(uuid,text,uuid)') IS NULL OR to_regclass('public.direct_order_delivery_cost_changes') IS NOT NULL THEN RAISE EXCEPTION 'DELIVERY_COST_PREDECESSOR_DRIFT'; END IF;
 IF md5(pg_get_functiondef('public.direct_order_staff_record_pickup_refund(uuid,uuid,uuid,text)'::regprocedure))<>'109fecf83ce1e568805f1a078ab30a48' THEN RAISE EXCEPTION 'PICKUP_REFUND_ANCHOR_DRIFT'; END IF;
END; $preflight$;
COMMIT;
