DO $$ BEGIN
 IF to_regprocedure('public.inventory_stock_at(uuid,timestamp with time zone)') IS NULL
 OR to_regprocedure('public.list_inventory_stock_audits(uuid,date)') IS NULL
 OR position('known:=registered<=p_at AND NOT unknown_history;' IN pg_get_functiondef('public.inventory_stock_at(uuid,timestamp with time zone)'::regprocedure))=0
 THEN RAISE EXCEPTION 'COUNTED_BALANCES_DEPENDENCY_CHANGED'; END IF;
 IF to_regprocedure('public.get_inventory_stock_audit_balances(uuid,date)') IS NOT NULL THEN RAISE EXCEPTION 'COUNTED_BALANCES_ALREADY_APPLIED'; END IF;
END $$;
