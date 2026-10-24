DO $$ DECLARE d text; BEGIN
 d:=pg_get_functiondef('public.cashier_move_order_items(uuid,uuid,uuid,jsonb,uuid)'::regprocedure);
 IF strpos(d,'WHERE m.source_item_id IS NOT NULL AND m.move_count>0')=0
 OR (length(d)-length(replace(d,'WHERE m.new_id IS NOT NULL AND m.units>0','')))/length('WHERE m.new_id IS NOT NULL AND m.units>0')<>2
 OR has_function_privilege('anon','public.cashier_move_order_items(uuid,uuid,uuid,jsonb,uuid)','EXECUTE')
 OR NOT has_function_privilege('authenticated','public.cashier_move_order_items(uuid,uuid,uuid,jsonb,uuid)','EXECUTE')
 OR has_function_privilege('anon','public.qr_table_payment_summary(uuid,uuid)','EXECUTE')
 OR has_function_privilege('authenticated','public.qr_table_payment_summary(uuid,uuid)','EXECUTE')
 OR has_function_privilege('anon','public.qr_get_active_order_before_payment_summary(text)','EXECUTE')
 OR NOT has_function_privilege('anon','public.qr_get_active_order(text)','EXECUTE')
 THEN RAISE EXCEPTION 'TABLE_MOVE_PAYMENT_SUMMARY_VERIFY_FAILED'; END IF;
 d:=pg_get_functiondef('public.emergency_enrich_qr_unserved_items(uuid,jsonb)'::regprocedure);
 IF strpos(d,'OFFSET')>0 OR strpos(d,'FOR v_item')>0 OR strpos(d,'order_item_id')=0
 THEN RAISE EXCEPTION 'QR_BALANCE_ENRICHMENT_NOT_BATCHED'; END IF;
END $$;
SELECT 'TABLE_MOVE_PAYMENT_SUMMARY_VERIFIED';
