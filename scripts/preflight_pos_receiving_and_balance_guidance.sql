-- Read-only production prerequisites. Do not create fixtures or change accounts.
DO $preflight$
DECLARE signature text;
BEGIN
 FOREACH signature IN ARRAY ARRAY[
  'public.direct_order_record_receipt(uuid,uuid,uuid,uuid,numeric,text)',
  'public.direct_order_support_context(uuid,boolean)',
  'public.get_inventory_order_catalog(uuid)',
  'public.get_inventory_workflow_detail(uuid)',
  'public.procurement_actor(uuid,jsonb)'
 ] LOOP
  IF to_regprocedure(signature) IS NULL THEN RAISE EXCEPTION 'Missing release prerequisite: %',signature; END IF;
 END LOOP;
 ASSERT to_regprocedure('public.direct_order_record_receipt_before_balance_guidance(uuid,uuid,uuid,uuid,numeric,text)') IS NULL,'Balance guide already installed';
 ASSERT to_regprocedure('public.get_inventory_order_catalog_before_receiving_guidance(uuid)') IS NULL,'Receiving guide already installed';
 ASSERT EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='inventory_items' AND column_name='current_stock'),'Missing stock contract';
 ASSERT EXISTS(SELECT 1 FROM information_schema.columns WHERE table_schema='public' AND table_name='inventory_products' AND column_name='inventory_item_id'),'Missing product/stock mapping';
 RAISE NOTICE 'POS_OPERATIONS_PREFLIGHT=PASS';
END $preflight$;
