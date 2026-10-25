DO $$ DECLARE d text; BEGIN
 d:=pg_get_functiondef('public.cashier_move_order_items(uuid,uuid,uuid,jsonb,uuid)'::regprocedure);
 IF strpos(d,'UPDATE pg_temp.workflow_move_map m SET copied=')=0
 OR strpos(d,'store_preparation_steps')=0 OR strpos(d,'CASHIER_OPERATION_CHANGED')=0
 OR to_regprocedure('public.qr_get_active_order_before_payment_summary(text)') IS NOT NULL
 OR to_regprocedure('public.calculate_item_vat(jsonb,numeric,text,numeric)') IS NULL
 THEN RAISE EXCEPTION 'TABLE_MOVE_PAYMENT_SUMMARY_PREDECESSOR_DRIFT'; END IF;
END $$;
