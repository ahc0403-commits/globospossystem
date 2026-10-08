BEGIN;
SET LOCAL request.jwt.claim.sub = '00000000-0000-4000-8000-000000000001';
CREATE SCHEMA receipt_requests_test;
CREATE FUNCTION receipt_requests_test.assert(p_ok boolean,p_message text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF p_ok IS DISTINCT FROM true THEN RAISE EXCEPTION '%',p_message; END IF; END $$;
DO $test$
DECLARE
  store uuid := 'd1000000-0000-4000-8000-000000000002';
  f jsonb; rid uuid; oid uuid; fee uuid; menu uuid; free_menu uuid;
  job public.print_jobs%ROWTYPE; old_job public.print_jobs%ROWTYPE;
  items jsonb; snapshot jsonb; enriched jsonb; digital uuid; original jsonb;
  stock numeric; payment_count integer; order_items_before jsonb; context jsonb;
BEGIN
  f := photo_test.create_request(); rid := (f->>'request_id')::uuid;
  UPDATE public.direct_order_requests SET fulfillment_method='pickup',
    diner_count=1, customer_note='No steamed rice' WHERE id=rid;
  UPDATE public.direct_order_request_items SET item_note='No onion' WHERE request_id=rid;
  oid := (photo_test.approve(f)->>'order_id')::uuid;
  SELECT delivery_fee_item_id INTO STRICT fee FROM public.direct_order_financials WHERE order_id=oid;
  SELECT id INTO STRICT menu FROM public.order_items WHERE order_id=oid AND item_type='menu_item';
  SELECT * INTO STRICT old_job FROM public.print_jobs WHERE order_id=oid;
  PERFORM receipt_requests_test.assert(old_job.payload->>'order_notes'='No steamed rice'
    AND jsonb_array_length(old_job.payload->'items')=1
    AND old_job.payload->'items'->0->>'notes'='No onion'
    AND old_job.payload->'items'->0->>'label'='Món thử', 'FIRST_RECEIPT_LOST_REQUESTS_OR_ZERO_FEE_VISIBLE');
  PERFORM receipt_requests_test.assert((SELECT count(*)=2 FROM public.order_items WHERE order_id=oid), 'FEE_REMOVED_FROM_FINANCIAL_RECORD');
  context := public.direct_order_receipt_packing_context(store,oid);
  PERFORM receipt_requests_test.assert(context->>'order_notes'='No steamed rice'
    AND context->>'delivery_fee_item_id'=fee::text
    AND (SELECT count(*)=5 FROM jsonb_object_keys(context)), 'NATIVE_RECEIPT_CONTEXT_MISMATCH');

  -- Put the fee between two menus. Zero-price menus must remain visible.
  INSERT INTO public.menu_items(id,restaurant_id,name,name_vi,vat_category,price)
    VALUES(gen_random_uuid(),store,'Free tea','Trà miễn phí','food',0) RETURNING id INTO free_menu;
  INSERT INTO public.order_items(restaurant_id,order_id,menu_item_id,item_type,label,display_name,
    quantity,unit_price,status,notes,created_at,is_service_item)
    VALUES(store,oid,free_menu,'menu_item','Free tea','Free tea',1,0,'served','No ice',
      '2026-10-08 00:00:02+00',false) RETURNING id INTO free_menu;
  UPDATE public.order_items SET created_at='2026-10-08 00:00:00+00' WHERE id=menu;
  UPDATE public.order_items SET created_at='2026-10-08 00:00:01+00' WHERE id=fee;
  INSERT INTO public.order_items(restaurant_id,order_id,item_type,label,quantity,unit_price,status,notes,created_at)
    VALUES(store,oid,'menu_item','Cancelled',1,100,'cancelled','Cancelled note','2026-10-07 00:00:00+00');
  SELECT jsonb_agg(to_jsonb(i) ORDER BY i.id) INTO order_items_before FROM public.order_items i WHERE order_id=oid;
  SELECT count(*) INTO payment_count FROM public.payments;
  SELECT current_stock INTO stock FROM public.inventory_items WHERE id='d1000000-0000-4000-8000-000000000004';
  job := public.enqueue_receipt_print_job(oid,true);
  PERFORM receipt_requests_test.assert(jsonb_array_length(job.payload->'items')=2
    AND job.payload->'items'->0->>'label'='Món thử'
    AND job.payload->'items'->0->>'notes'='No onion'
    AND job.payload->'items'->1->>'label'='Trà miễn phí'
    AND job.payload->'items'->1->>'notes'='No ice'
    AND job.payload->>'total_amount'='108000.00', 'REPRINT_SHIFTED_MENU_NOTES_OR_HID_FREE_MENU');
  SELECT jsonb_agg(jsonb_build_object('label',i.label,'quantity',i.quantity,
    'unit_price',i.unit_price,'line_total',i.unit_price*i.quantity,'vat_amount',i.vat_amount,
    'item_type',i.item_type,'is_service_item',i.is_service_item) ORDER BY i.created_at,i.id)
    INTO items FROM public.order_items i WHERE order_id=oid AND status<>'cancelled';
  snapshot := jsonb_build_object('items',items,'total_amount',108000,'vat_amount',8000,'payments',jsonb_build_array('unchanged'));
  INSERT INTO public.digital_receipts(restaurant_id,order_id,snapshot)
    VALUES(store,oid,snapshot) RETURNING id,digital_receipts.snapshot INTO digital,enriched;
  PERFORM receipt_requests_test.assert(enriched->>'order_notes'='No steamed rice'
    AND jsonb_array_length(enriched->'items')=2
    AND enriched->'items'->1->>'label'='Trà miễn phí'
    AND enriched->'items'->1->>'notes'='No ice'
    AND (enriched->'items'->0) - ARRAY['label','notes','item_id']=(items->0) - ARRAY['label','notes','item_id']
    AND (enriched->'items'->1) - ARRAY['label','notes','item_id']=(items->2) - ARRAY['label','notes','item_id']
    AND enriched - ARRAY['items','order_notes','diner_count','fulfillment_method','direct_order_reference']=snapshot - 'items',
    'DIGITAL_RECEIPT_CHANGED_FINANCIALS_OR_LOST_REQUESTS');
  original := enriched;
  UPDATE public.direct_order_requests SET customer_note='No chilli' WHERE id=rid;
  job := public.enqueue_receipt_print_job(oid,true);
  PERFORM receipt_requests_test.assert(job.payload->>'order_notes'='No chilli'
    AND (SELECT payload=old_job.payload FROM public.print_jobs WHERE id=old_job.id)
    AND (SELECT d.snapshot=original FROM public.digital_receipts d WHERE id=digital), 'ISSUED_SNAPSHOT_MUTATED_OR_REPRINT_STALE');
  PERFORM receipt_requests_test.assert((SELECT jsonb_agg(to_jsonb(i) ORDER BY i.id)=order_items_before FROM public.order_items i WHERE order_id=oid)
    AND (SELECT count(*)=payment_count FROM public.payments)
    AND (SELECT current_stock=stock FROM public.inventory_items WHERE id='d1000000-0000-4000-8000-000000000004'), 'RECEIPT_CHANGED_PAYMENTS_ITEMS_OR_STOCK');

  -- Pickup hides the fee even when this order originally paid for delivery.
  UPDATE public.order_items SET unit_price=20000 WHERE id=fee;
  items := jsonb_build_array(
    jsonb_build_object('item_id',free_menu,'label','Trà miễn phí','unit_price',0),
    jsonb_build_object('item_id',fee,'label','Món','unit_price',20000),
    jsonb_build_object('item_id',menu,'label','Món thử','unit_price',100000));
  enriched := public.direct_order_receipt_content(store,oid,items);
  PERFORM receipt_requests_test.assert(jsonb_array_length(enriched->'items')=2
    AND enriched->'items'->0->>'notes'='No ice'
    AND enriched->'items'->1->>'notes'='No onion', 'PICKUP_SHOWED_ORIGINAL_DELIVERY_FEE');
  -- Explicit IDs win over position. Actual delivery shows the charged Grab fee.
  UPDATE public.direct_order_requests SET fulfillment_method='delivery' WHERE id=rid;
  enriched := public.direct_order_receipt_content(store,oid,items);
  PERFORM receipt_requests_test.assert(jsonb_array_length(enriched->'items')=3
    AND enriched->'items'->0->>'notes'='No ice'
    AND enriched->'items'->1->>'label'='Phí giao hàng'
    AND enriched->'items'->1->>'unit_price'='20000'
    AND enriched->'items'->2->>'notes'='No onion', 'ID_MATCH_OR_PAID_DELIVERY_FEE_MISMATCH');
  UPDATE public.order_items SET unit_price=0 WHERE id=fee;
  items := jsonb_set(items,'{1,unit_price}','0'::jsonb);
  enriched := public.direct_order_receipt_content(store,oid,items);
  PERFORM receipt_requests_test.assert(jsonb_array_length(enriched->'items')=3
    AND enriched->'items'->1->>'label'='Phí giao hàng'
    AND enriched->'items'->1->>'unit_price'='0', 'DELIVERY_ZERO_GRAB_FEE_MISLABELLED');
  UPDATE public.direct_order_requests SET customer_note='  ' WHERE id=rid;
  PERFORM receipt_requests_test.assert(public.direct_order_receipt_content(store,oid,items)->'order_notes'='null'::jsonb, 'BLANK_NOTE_OR_INTERNAL_ORDER_NOTE_LEAKED');
  PERFORM receipt_requests_test.assert(public.direct_order_receipt_content(gen_random_uuid(),oid,items) IS NULL, 'CROSS_STORE_RECEIPT_ENRICHED');
  -- Check the actual query plan as the menu list grows: the order rows are
  -- fetched once, with no correlated per-item subplan or extra RPC.
  DECLARE
    size integer; plan jsonb; source text; query text; row_loops integer; subplans integer;
  BEGIN
    SELECT p.prosrc INTO source FROM pg_proc p
      WHERE p.oid='public.direct_order_receipt_content(uuid,uuid,jsonb)'::regprocedure;
    FOR size IN SELECT unnest(ARRAY[1,100,500]) LOOP
      DELETE FROM public.order_items WHERE order_id=oid AND id NOT IN (menu,fee,free_menu);
      INSERT INTO public.order_items(restaurant_id,order_id,item_type,label,quantity,unit_price,status,notes,created_at)
        SELECT store,oid,'menu_item','Batch menu',1,0,'served','Batch request',
          '2026-10-08 00:00:03+00'::timestamptz + n * interval '1 second'
        FROM generate_series(1,size) n;
      SELECT jsonb_agg(jsonb_build_object('label',label,'unit_price',unit_price)
        ORDER BY created_at,id) INTO items FROM public.order_items WHERE order_id=oid AND status<>'cancelled';
      query := replace(replace(replace(source,
        'p_store_id',quote_literal(store)||'::uuid'),
        'p_order_id',quote_literal(oid)||'::uuid'),
        'p_items',quote_literal(items)||'::jsonb');
      EXECUTE 'EXPLAIN (ANALYZE, FORMAT JSON) '||query INTO plan;
      WITH RECURSIVE nodes(node) AS (
        SELECT plan->0->'Plan'
        UNION ALL SELECT child FROM nodes,
          jsonb_array_elements(COALESCE(node->'Plans','[]'::jsonb)) child
      ) SELECT COALESCE(max((node->>'Actual Loops')::integer)
          FILTER (WHERE node->>'Relation Name'='order_items'),0),
        count(*) FILTER (WHERE node->>'Parent Relationship'='SubPlan')
        INTO row_loops,subplans FROM nodes;
      PERFORM receipt_requests_test.assert(row_loops=1 AND subplans=0, 'RECEIPT_ITEMS_N_PLUS_ONE');
      RAISE NOTICE 'DIRECT_ORDER_RECEIPT_BATCH=PASS menus=% order_item_scan_loops=% correlated_subplans=%',size,row_loops,subplans;
    END LOOP;
  END;
  INSERT INTO public.orders(restaurant_id,status) VALUES(store,'completed') RETURNING id INTO oid;
  PERFORM receipt_requests_test.assert(public.direct_order_receipt_content(store,oid,items) IS NULL, 'REGULAR_ORDER_CHANGED');
  snapshot := jsonb_build_object('items','[]'::jsonb,'total_amount',100);
  INSERT INTO public.digital_receipts(restaurant_id,order_id,snapshot)
    VALUES(store,oid,snapshot) RETURNING digital_receipts.snapshot INTO enriched;
  PERFORM receipt_requests_test.assert(enriched=snapshot, 'REGULAR_DIGITAL_RECEIPT_CHANGED');
END;
$test$;
ROLLBACK;
SELECT 'DIRECT_ORDER_RECEIPT_REQUESTS_SQL_TEST=PASS';
