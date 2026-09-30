DO $$ BEGIN
 IF to_regclass('public.inventory_stock_audit_sessions') IS NULL OR to_regclass('public.inventory_stock_audit_lines') IS NULL OR to_regprocedure('public.can_access_inventory_purchase_store(uuid)') IS NULL THEN RAISE EXCEPTION 'STOCK_AUDIT_DEPENDENCIES_MISSING'; END IF;
END $$;
