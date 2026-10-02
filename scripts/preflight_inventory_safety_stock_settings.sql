DO $$ BEGIN
 IF to_regprocedure('public.upsert_inventory_product_with_supplier(uuid,uuid,uuid,text,text,text,text,text,numeric,text,text,integer,boolean,text)') IS NULL
 OR to_regprocedure('public.upsert_inventory_product(uuid,uuid,text,text,text,text,text,numeric,text,text,integer,boolean)') IS NULL
 OR to_regprocedure('public.upsert_inventory_supplier_item(uuid,uuid,uuid,uuid,text,text,numeric,numeric,numeric,numeric,integer,boolean)') IS NULL
 OR to_regprocedure('public.can_access_inventory_purchase_store(uuid)') IS NULL
 OR to_regclass('public.audit_logs') IS NULL
 OR NOT EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='inventory_items' AND column_name='reorder_point')
 THEN RAISE EXCEPTION 'SAFETY_STOCK_DEPENDENCY_MISSING'; END IF;
 IF to_regprocedure('public.upsert_inventory_product_with_supplier_v2(uuid,uuid,uuid,text,text,text,text,text,numeric,text,text,integer,boolean,text,numeric)') IS NOT NULL
 THEN RAISE EXCEPTION 'SAFETY_STOCK_ALREADY_APPLIED'; END IF;
END $$;
