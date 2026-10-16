-- Catalog and grants only; no business writes or operational messages.
DO $verify$
DECLARE signature text;
BEGIN
 FOREACH signature IN ARRAY ARRAY[
  'public.direct_order_record_receipt(uuid,uuid,uuid,uuid,numeric,text)',
  'public.get_inventory_order_catalog(uuid)',
  'public.get_inventory_workflow_detail(uuid)'
 ] LOOP
  ASSERT has_function_privilege('authenticated',signature,'EXECUTE'),'Required authenticated RPC grant missing';
  ASSERT NOT has_function_privilege('anon',signature,'EXECUTE'),'Anonymous staff RPC access';
 END LOOP;
 FOREACH signature IN ARRAY ARRAY[
  'public.direct_order_record_receipt_before_balance_guidance(uuid,uuid,uuid,uuid,numeric,text)',
  'public.get_inventory_order_catalog_before_receiving_guidance(uuid)',
  'public.get_inventory_workflow_detail_before_receiving_guidance(uuid)'
 ] LOOP
  ASSERT NOT has_function_privilege('authenticated',signature,'EXECUTE'),'Private predecessor exposed';
 END LOOP;
 ASSERT pg_get_functiondef('public.direct_order_record_receipt(uuid,uuid,uuid,uuid,numeric,text)'::regprocedure) LIKE '%direct_order_record_receipt_before_balance_guidance%','Receipt predecessor not retained';
 ASSERT pg_get_functiondef('public.get_inventory_order_catalog(uuid)'::regprocedure) LIKE '%receiving_only%','Receiving capability missing';
 ASSERT pg_get_functiondef('public.get_inventory_workflow_detail(uuid)'::regprocedure) LIKE '%current_stock_base%','Selected-order stock missing';
 RAISE NOTICE 'POS_OPERATIONS_VERIFY=PASS';
END $verify$;
