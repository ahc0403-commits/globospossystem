DO $$ DECLARE fn regprocedure := to_regprocedure('public.upsert_inventory_product_with_supplier_v2(uuid,uuid,uuid,text,text,text,text,text,numeric,text,text,integer,boolean,text,numeric)'); BEGIN
 IF fn IS NULL OR has_function_privilege('anon',fn,'EXECUTE')
 OR NOT has_function_privilege('authenticated',fn,'EXECUTE')
 OR position('INVENTORY_SAFETY_STOCK_INVALID' IN pg_get_functiondef(fn))=0
 OR to_regprocedure('public.set_inventory_product_safety_stock(uuid,uuid,numeric,text)') IS NULL
 OR has_function_privilege('anon','public.set_inventory_product_safety_stock(uuid,uuid,numeric,text)','EXECUTE')
 OR NOT has_function_privilege('authenticated','public.set_inventory_product_safety_stock(uuid,uuid,numeric,text)','EXECUTE')
 OR position('inventory_safety_stock_updated' IN pg_get_functiondef('public.set_inventory_product_safety_stock(uuid,uuid,numeric,text)'::regprocedure))=0
 OR position('public.upsert_inventory_supplier_item(' IN pg_get_functiondef(fn))=0
 THEN RAISE EXCEPTION 'SAFETY_STOCK_CONTRACT_INVALID'; END IF;
END $$;
