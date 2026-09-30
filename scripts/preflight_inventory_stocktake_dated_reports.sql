DO $$ BEGIN
 IF to_regprocedure('public.save_inventory_stock_audit_v2(uuid,uuid,integer,jsonb,boolean,text)') IS NULL
 OR to_regclass('public.payments') IS NULL OR to_regclass('public.order_items') IS NULL THEN RAISE EXCEPTION 'STOCKTAKE_DATED_DEPENDENCIES_MISSING'; END IF;
 IF to_regclass('public.inventory_stock_movements') IS NOT NULL THEN RAISE EXCEPTION 'STOCKTAKE_DATED_ALREADY_APPLIED'; END IF;
END $$;
