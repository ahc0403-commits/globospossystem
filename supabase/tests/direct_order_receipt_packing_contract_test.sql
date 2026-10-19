BEGIN;
CREATE FUNCTION fallback_test.assert(p_ok boolean,p_message text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF p_ok IS DISTINCT FROM true THEN RAISE EXCEPTION '%',p_message; END IF; END $$;
CREATE FUNCTION fallback_test.expect_error(p_sql text,p_error text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE actual text;
BEGIN BEGIN EXECUTE p_sql; EXCEPTION WHEN OTHERS THEN actual:=SQLERRM; END;
 PERFORM fallback_test.assert(actual=p_error,format('EXPECTED %s, GOT %s',p_error,actual)); END $$;
DO $test$
DECLARE
  f jsonb; result jsonb; context jsonb; original_snapshot jsonb;
  store uuid := 'd1000000-0000-4000-8000-000000000002';
  rid uuid; oid uuid; regular uuid; legacy uuid; digital uuid;
  before_stock numeric; before_payments integer; before_tickets integer;
  receipt public.print_jobs%ROWTYPE; old_job public.print_jobs%ROWTYPE;
  test_status text;
BEGIN
  SELECT current_stock INTO before_stock FROM public.inventory_items
    WHERE id='d1000000-0000-4000-8000-000000000004';
  f := photo_test.create_request(); rid := (f->>'request_id')::uuid;
  UPDATE public.direct_order_requests SET diner_count=3 WHERE id=rid;
  result := photo_test.approve(f); oid := (result->>'order_id')::uuid;
  -- Real financials AFTER INSERT -> enqueue -> new print BEFORE INSERT.
  SELECT * INTO STRICT old_job FROM public.print_jobs WHERE order_id=oid;
  PERFORM fallback_test.assert(old_job.payload->>'diner_count'='3'
    AND old_job.payload->>'fulfillment_method'='delivery'
    AND old_job.payload->>'direct_order_reference' IS NOT NULL
    AND old_job.status='pending', 'FIRST_PAID_RECEIPT_LOST_PACKING_COUNT');
  PERFORM fallback_test.assert((SELECT guest_count=3 FROM public.orders WHERE id=oid), 'PACKING_ORDER_COUNT_LOST');
  SELECT count(*) INTO before_payments FROM public.payments;
  SELECT count(*) INTO before_tickets FROM public.direct_delivery_fulfillment_tickets;
  context := public.direct_order_receipt_packing_context(store,oid);
  PERFORM fallback_test.assert(context->>'diner_count'='3'
    AND (SELECT count(*)=3 FROM jsonb_object_keys(context)), 'PACKING_CONTEXT_PRIVACY_OR_COUNT');
  PERFORM fallback_test.assert((SELECT count(*)=1 FROM public.print_jobs WHERE order_id=oid), 'READ_CONTEXT_ENQUEUED_DUPLICATE');
  FOR test_status IN SELECT unnest(ARRAY['kitchen','floor','tray','confirmation']) LOOP
    INSERT INTO public.print_jobs(order_id,restaurant_id,copy_type,payload)
      VALUES(oid,store,test_status,jsonb_build_object('ticket',test_status))
      RETURNING * INTO receipt;
    PERFORM fallback_test.assert(receipt.payload->>'diner_count'='3'
      AND receipt.payload->>'fulfillment_method'='delivery'
      AND receipt.payload->>'direct_order_reference' IS NOT NULL,
      'OPERATIONAL_PRINT_FORM_LOST_PACKING_CONTEXT');
  END LOOP;
  PERFORM fallback_test.expect_error(format('SELECT public.direct_order_receipt_packing_context(%L,%L)',gen_random_uuid(),oid),'DIRECT_ORDER_FORBIDDEN');
  UPDATE public.users SET role='kitchen' WHERE auth_id=auth.uid();
  PERFORM fallback_test.expect_error(format('SELECT public.direct_order_receipt_packing_context(%L,%L)',store,oid),'DIRECT_ORDER_FORBIDDEN');
  UPDATE public.users SET role='cashier' WHERE auth_id=auth.uid();
  PERFORM fallback_test.expect_error(format('SELECT public.direct_order_receipt_packing_context(%L,%L)',store,gen_random_uuid()),'RECEIPT_ORDER_NOT_FOUND');

  original_snapshot := jsonb_build_object('total_amount',108000,'vat_amount',8000,'items','[]'::jsonb);
  INSERT INTO public.digital_receipts(restaurant_id,order_id,snapshot)
    VALUES(store,oid,original_snapshot) RETURNING id INTO digital;
  PERFORM fallback_test.assert((SELECT snapshot->>'diner_count'='3'
    AND snapshot - ARRAY['diner_count','fulfillment_method','direct_order_reference']=original_snapshot
    FROM public.digital_receipts WHERE id=digital), 'DIGITAL_PACKING_CHANGED_FINANCIAL_SNAPSHOT');
  FOR test_status IN SELECT unnest(ARRAY['failed','printing','done']) LOOP
    receipt := public.enqueue_receipt_print_job(oid,true);
    UPDATE public.print_jobs SET status=test_status WHERE id=receipt.id;
  END LOOP;
  PERFORM public.direct_order_staff_set_diner_count(store,rid,1,5);
  PERFORM fallback_test.assert((SELECT guest_count=5 FROM public.orders WHERE id=oid), 'CURRENT_PACKING_COUNT_NOT_UPDATED');
  PERFORM fallback_test.assert(NOT EXISTS(SELECT 1 FROM public.print_jobs WHERE order_id=oid AND payload->>'diner_count'<>'3'), 'OLD_JOB_SNAPSHOT_MUTATED');
  PERFORM fallback_test.assert((SELECT snapshot->>'diner_count'='3' FROM public.digital_receipts WHERE id=digital), 'ISSUED_DIGITAL_SNAPSHOT_MUTATED');
  receipt := public.enqueue_receipt_print_job(oid,true);
  PERFORM fallback_test.assert(receipt.payload->>'diner_count'='5'
    AND receipt.payload->>'printed_reason'='reprint' AND receipt.batch_no=5, 'NEW_REPRINT_NOT_CURRENT_PACKING_COUNT');
  PERFORM fallback_test.assert(public.direct_order_receipt_packing_context(store,oid)->>'diner_count'='5', 'NATIVE_CONTEXT_STALE');
  PERFORM fallback_test.assert((SELECT count(*)=before_payments FROM public.payments)
    AND (SELECT count(*)=before_tickets FROM public.direct_delivery_fulfillment_tickets)
    AND (SELECT current_stock=before_stock-10 FROM public.inventory_items WHERE id='d1000000-0000-4000-8000-000000000004'), 'PACKING_REPRINT_CHANGED_PAYMENT_OR_INVENTORY');

  INSERT INTO public.orders(restaurant_id,status,guest_count) VALUES(store,'completed',100) RETURNING id INTO regular;
  PERFORM fallback_test.assert(public.direct_order_receipt_packing_context(store,regular) IS NULL, 'REGULAR_GUESTS_BECAME_DISPOSABLE_SETS');
  INSERT INTO public.digital_receipts(restaurant_id,order_id,snapshot) VALUES(store,regular,original_snapshot);
  PERFORM fallback_test.assert((SELECT snapshot=original_snapshot FROM public.digital_receipts WHERE order_id=regular), 'REGULAR_DIGITAL_SNAPSHOT_CHANGED');

  f := photo_test.create_request(); rid := (f->>'request_id')::uuid;
  result := photo_test.approve(f); legacy := (result->>'order_id')::uuid;
  context := public.direct_order_receipt_packing_context(store,legacy);
  PERFORM fallback_test.assert(context->'diner_count'='null'::jsonb AND context->>'direct_order_reference' IS NOT NULL, 'LEGACY_COUNT_INVENTED_OR_DIRECT_ID_LOST');
  INSERT INTO public.digital_receipts(restaurant_id,order_id,combined_payment_group_id,snapshot)
    VALUES(store,legacy,gen_random_uuid(),original_snapshot);
  PERFORM fallback_test.assert((SELECT snapshot=original_snapshot FROM public.digital_receipts WHERE order_id=legacy), 'COMBINED_DIGITAL_SNAPSHOT_CHANGED');
END;
$test$;
ROLLBACK;
SELECT 'DIRECT_ORDER_RECEIPT_PACKING_SQL_TEST=PASS';
