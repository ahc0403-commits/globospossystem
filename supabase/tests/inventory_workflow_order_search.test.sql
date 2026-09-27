BEGIN;
SET ROLE authenticated;
DO $order_search$
DECLARE
  po public.inventory_purchase_orders%ROWTYPE;
  result jsonb;
  product_name text;
  supplier_name text;
BEGIN
  PERFORM set_config('request.jwt.claim.sub', test_uuid(1)::text, true);
  po := public.create_manual_inventory_purchase_order(
    test_uuid(101), test_uuid(201),
    jsonb_build_array(jsonb_build_object('supplier_item_id', test_uuid(401), 'ordered_quantity_unit', 1)),
    current_date, NULL);
  SELECT name INTO product_name FROM public.inventory_products WHERE id=test_uuid(301);
  SELECT s.supplier_name INTO supplier_name FROM public.inventory_suppliers s WHERE id=test_uuid(201);
  result := public.search_inventory_workflow_orders(test_uuid(101), NULL, false, 0, 80, po.purchase_order_no);
  ASSERT result->'orders'->0->>'id'=po.id::text, 'Search by order number must find matching PO';
  result := public.search_inventory_workflow_orders(test_uuid(101), NULL, false, 0, 80, product_name);
  ASSERT EXISTS (SELECT 1 FROM jsonb_array_elements(result->'orders') o WHERE o->>'id'=po.id::text),
    'Search by ingredient must include matching PO';
  result := public.search_inventory_workflow_orders(test_uuid(101), NULL, false, 0, 80, supplier_name);
  ASSERT EXISTS (SELECT 1 FROM jsonb_array_elements(result->'orders') o WHERE o->>'id'=po.id::text),
    'Search by supplier must include matching PO';
  ASSERT (result->>'total')::integer >= jsonb_array_length(result->'orders');
  PERFORM set_config('request.jwt.claim.sub', test_uuid(2)::text, true);
  result := public.search_inventory_workflow_orders(test_uuid(101), NULL, false, 0, 80, po.purchase_order_no);
  ASSERT result->'orders'->0->>'id'=po.id::text, 'Store Manager must find accessible order';
  PERFORM set_config('request.jwt.claim.sub', test_uuid(3)::text, true);
  result := public.search_inventory_workflow_orders(test_uuid(101), NULL, false, 0, 80, po.purchase_order_no);
  ASSERT result->'orders'->0->>'id'=po.id::text, 'Brand Manager must find accessible order';
  PERFORM set_config('request.jwt.claim.sub', test_uuid(1)::text, true);
  PERFORM public.test_expect_error(format(
    'SELECT public.search_inventory_workflow_orders(%L,NULL,false,0,80,%L)',
    test_uuid(102), po.purchase_order_no), 'INVENTORY_PURCHASE_FORBIDDEN');
  RAISE NOTICE 'PASS: server search for PO, ingredient and supplier preserves store scope';
END $order_search$;
ROLLBACK;
