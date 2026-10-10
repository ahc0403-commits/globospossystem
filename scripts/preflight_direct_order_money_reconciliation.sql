BEGIN READ ONLY;
DO $preflight$
BEGIN
 IF md5(pg_get_functiondef('public.process_payment(uuid,uuid,numeric,text)'::regprocedure))<>'be39d85b3e5ba56462745470db5a79db' THEN RAISE EXCEPTION 'PAYMENT_ANCHOR_DRIFT'; END IF;
 IF to_regprocedure('public.direct_order_staff_list_v3(uuid,text[],integer,text)') IS NULL
 OR to_regprocedure('public.direct_order_staff_support_before_cost(uuid,uuid,integer,text,jsonb)') IS NULL
 OR to_regprocedure('public.direct_order_original_delivery_refund_remaining(uuid)') IS NULL
 OR to_regclass('public.direct_order_driver_cash_movements') IS NOT NULL THEN RAISE EXCEPTION 'RECONCILIATION_PREDECESSOR_DRIFT'; END IF;
 IF EXISTS(SELECT 1 FROM public.direct_order_payment_receipts WHERE amount<=0 OR amount::text IN ('NaN','Infinity','-Infinity')) THEN RAISE EXCEPTION 'RECONCILIATION_LEGACY_RECEIPT_INVALID'; END IF;
END; $preflight$;
COMMIT;
