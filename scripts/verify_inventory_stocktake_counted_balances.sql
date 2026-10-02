DO $$ BEGIN
 IF to_regprocedure('public.get_inventory_stock_audit_balances(uuid,date)') IS NULL
 OR position('counted_anchor' IN pg_get_functiondef('public.inventory_stock_at(uuid,timestamp with time zone)'::regprocedure))=0
 OR has_function_privilege('anon','public.get_inventory_stock_audit_balances(uuid,date)','EXECUTE')
 OR NOT has_function_privilege('authenticated','public.get_inventory_stock_audit_balances(uuid,date)','EXECUTE')
 OR has_function_privilege('authenticated','public.inventory_stock_at(uuid,timestamp with time zone)','EXECUTE')
 THEN RAISE EXCEPTION 'COUNTED_BALANCES_CONTRACT_INVALID'; END IF;
END $$;
