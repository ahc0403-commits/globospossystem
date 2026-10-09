BEGIN READ ONLY;
DO $preflight$ BEGIN
 IF md5(pg_get_functiondef('public.process_payment(uuid,uuid,numeric,text)'::regprocedure))<>'be39d85b3e5ba56462745470db5a79db' THEN RAISE EXCEPTION 'PAYMENT_ANCHOR_DRIFT'; END IF;
 IF to_regclass('public.cashier_item_operations') IS NOT NULL THEN RAISE EXCEPTION 'CASHIER_ITEM_EDIT_ALREADY_INSTALLED'; END IF;
 IF md5(pg_get_functiondef('public.cancel_order_item(uuid,uuid)'::regprocedure))<>'7330438b57b7fbde66b365fc62fc3b7a'
 OR md5(pg_get_functiondef('public.restore_cancelled_order_item(uuid,uuid)'::regprocedure))<>'38a1361b60a50b67ea3563a2e2295a04'
 OR md5(split_part(pg_get_functiondef('public.process_payment_without_scoped_promotions(uuid,uuid,numeric,text)'::regprocedure),'oi.quantity AS ordered_qty',1))<>'e29a54454c55f7233d51fbe480f91ee3' THEN RAISE EXCEPTION 'CASHIER_FINANCIAL_PREDECESSOR_DRIFT'; END IF;
END; $preflight$;
COMMIT;
