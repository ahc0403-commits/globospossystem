BEGIN READ ONLY;
DO $verify$ BEGIN
 IF md5(pg_get_functiondef('public.process_payment(uuid,uuid,numeric,text)'::regprocedure))<>'be39d85b3e5ba56462745470db5a79db' THEN RAISE EXCEPTION 'PAYMENT_ANCHOR_DRIFT'; END IF;
 IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid='public.cashier_item_operations'::regclass)
 OR has_table_privilege('authenticated','public.cashier_item_operations','INSERT') THEN RAISE EXCEPTION 'CASHIER_AUDIT_RLS_DRIFT'; END IF;
 IF EXISTS(SELECT 1 FROM pg_proc WHERE oid IN ('public.cashier_cancel_item_quantity(uuid,uuid,integer,integer,uuid,text)'::regprocedure,'public.cashier_restore_item_quantity(uuid,uuid)'::regprocedure,'public.cashier_move_order_items(uuid,uuid,uuid,jsonb,uuid)'::regprocedure) AND (NOT prosecdef OR has_function_privilege('anon',oid,'EXECUTE') OR NOT has_function_privilege('authenticated',oid,'EXECUTE'))) THEN RAISE EXCEPTION 'CASHIER_ITEM_EDIT_RPC_PERMISSION_DRIFT'; END IF;
 IF md5(split_part(pg_get_functiondef('public.process_payment_without_scoped_promotions(uuid,uuid,numeric,text)'::regprocedure),'CASE WHEN oi.status=''cancelled'' THEN oi.cancelled_consumed_quantity ELSE oi.quantity+oi.cancelled_consumed_quantity END AS ordered_qty',1))<>'e29a54454c55f7233d51fbe480f91ee3' THEN RAISE EXCEPTION 'PAYMENT_FINANCIAL_FORMULAS_CHANGED'; END IF;
 IF (SELECT count(*) FROM pg_trigger WHERE NOT tgisinternal AND tgenabled='O' AND tgname IN ('cashier_item_operation_immutable','zzzz_cashier_partial_progress_sync'))<>2 THEN RAISE EXCEPTION 'CASHIER_ITEM_EDIT_TRIGGER_DRIFT'; END IF;
END; $verify$;
COMMIT;
