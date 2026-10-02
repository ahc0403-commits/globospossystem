-- Retain configured thresholds, physical counts, ledger, and the old client RPC.
DROP FUNCTION IF EXISTS public.upsert_inventory_product_with_supplier_v2(
 UUID,UUID,UUID,TEXT,TEXT,TEXT,TEXT,TEXT,NUMERIC,TEXT,TEXT,INT,BOOLEAN,TEXT,NUMERIC
);
NOTIFY pgrst, 'reload schema';
