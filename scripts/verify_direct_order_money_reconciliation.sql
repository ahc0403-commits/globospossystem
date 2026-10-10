BEGIN READ ONLY;
DO $verify$
BEGIN
 IF md5(pg_get_functiondef('public.process_payment(uuid,uuid,numeric,text)'::regprocedure))<>'be39d85b3e5ba56462745470db5a79db' THEN RAISE EXCEPTION 'PAYMENT_ANCHOR_DRIFT'; END IF;
 IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid='public.direct_order_driver_cash_movements'::regclass)
 OR has_table_privilege('authenticated','public.direct_order_driver_cash_movements','SELECT')
 OR has_table_privilege('authenticated','public.direct_order_refund_evidence','SELECT')
 OR has_function_privilege('authenticated','public.direct_order_staff_record_pickup_refund(uuid,uuid,uuid,text)','EXECUTE')
 OR NOT has_function_privilege('authenticated','public.direct_order_set_dispatch_v4(uuid,uuid,integer,text,text,numeric,text,text,boolean,uuid,uuid,text)','EXECUTE') THEN RAISE EXCEPTION 'RECONCILIATION_PERMISSION_DRIFT'; END IF;
 IF EXISTS(SELECT 1 FROM public.direct_order_payment_receipts WHERE actual_amount IS NULL OR actual_amount<amount)
 OR EXISTS(SELECT 1 FROM public.direct_order_dispatches d WHERE actual_grab_fee>0 AND cash_paid_at IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.direct_order_driver_cash_movements c WHERE c.request_id=d.request_id AND c.reason='handoff' AND c.amount=d.actual_grab_fee)) THEN RAISE EXCEPTION 'RECONCILIATION_LEDGER_BACKFILL_DRIFT'; END IF;
 IF strpos(pg_get_functiondef('public.direct_order_staff_list_before_reconciliation(uuid,text[],integer,text)'::regprocedure),'receipt_excess')=0
 OR strpos(pg_get_functiondef('public.get_daily_closing_cash_preview(uuid,date)'::regprocedure),'direct_order_cash_refunds')=0 THEN RAISE EXCEPTION 'RECONCILIATION_RUNTIME_GUARD_MISSING'; END IF;
END; $verify$;
COMMIT;
