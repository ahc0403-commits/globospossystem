-- Verified payment, delivery-fee ownership, and customer-bill regression.
-- Disposable codex_direct_* DB only.
\set ON_ERROR_STOP on

BEGIN;
\ir fixtures/direct_delivery_test_fixture.sql

DO $contract$
DECLARE
  v_store uuid;
  v_unverified jsonb;
  v_direct jsonb;
  v_unverified_request uuid;
  v_direct_request uuid;
  v_quote jsonb;
  v_transaction uuid;
  v_approval jsonb;
  v_order uuid;
  v_ticket uuid;
  v_transition jsonb;
  v_job_before uuid;
  v_job_after uuid;
  v_error text;
BEGIN
  SELECT store_id INTO v_store FROM direct_delivery_test.constants LIMIT 1;

  -- An uploaded image is not bank evidence and cannot authorize fulfillment.
  v_unverified := direct_delivery_test.create_request('payment_review');
  v_unverified_request := (v_unverified->>'request_id')::uuid;
  PERFORM direct_delivery_test.set_actor();
  BEGIN
    PERFORM public.direct_order_approve_payment(
      v_store,
      v_unverified_request,
      (v_unverified->>'final_total')::numeric,
      'image-only'
    );
  EXCEPTION WHEN OTHERS THEN
    v_error := SQLERRM;
  END;
  IF v_error <> 'DIRECT_ORDER_VERIFIED_PAYMENT_REQUIRED'
     OR EXISTS (
       SELECT 1 FROM public.direct_order_financials
       WHERE request_id = v_unverified_request
     ) THEN
    RAISE EXCEPTION 'image-only approval was not blocked: %', v_error;
  END IF;

  INSERT INTO public.sepay_transactions(
    sepay_transaction_id, restaurant_id, gateway, account_number,
    transfer_type, transfer_amount, payment_code, reference_code,
    transaction_at, resolution_status, raw_payload
  ) VALUES (
    99000001, v_store, 'MB', '123456789', 'in',
    (v_unverified->>'final_total')::numeric,
    'PILOTSAFE1', 'pilot-safety-1', now(), 'matched',
    jsonb_build_object('source', 'pilot_safety_test')
  ) RETURNING id INTO v_transaction;
  PERFORM direct_delivery_test.set_actor();
  PERFORM public.direct_order_staff_link_sepay(
    v_store, v_unverified_request, v_transaction
  );
  v_approval := public.direct_order_approve_verified_payment(
    v_store, v_unverified_request
  );
  IF (v_approval->>'idempotent')::boolean
     OR NOT EXISTS (
       SELECT 1 FROM public.direct_order_financials
       WHERE request_id = v_unverified_request
     ) THEN
    RAISE EXCEPTION 'verified approval did not create the financial graph';
  END IF;

  -- One provider transaction must never be consumed by a second request.
  v_direct := direct_delivery_test.create_request('payment_review');
  PERFORM direct_delivery_test.set_actor();
  v_error := NULL;
  BEGIN
    PERFORM public.direct_order_staff_link_sepay(
      v_store, (v_direct->>'request_id')::uuid, v_transaction
    );
  EXCEPTION WHEN OTHERS THEN
    v_error := SQLERRM;
  END;
  IF v_error <> 'DIRECT_ORDER_SEPAY_TRANSACTION_ALREADY_USED' THEN
    RAISE EXCEPTION 'transaction reuse was not blocked: %', v_error;
  END IF;

  -- The normal policy excludes delivery fees from store payment and cash close.
  v_direct := direct_delivery_test.create_request('awaiting_quote');
  v_direct_request := (v_direct->>'request_id')::uuid;
  PERFORM direct_delivery_test.set_actor();
  v_quote := public.direct_order_staff_quote_with_payment_mode(
    v_store, v_direct_request, 0, 'customer pays driver', 'customer_direct'
  );
  IF v_quote->>'delivery_payment_mode' <> 'customer_direct'
     OR (v_quote->>'delivery_fee_total')::numeric <> 0
     OR (v_quote->>'final_total')::numeric < 1 THEN
    RAISE EXCEPTION 'customer-direct quote is invalid: %', v_quote;
  END IF;

  INSERT INTO public.sepay_transactions(
    sepay_transaction_id, restaurant_id, gateway, account_number,
    transfer_type, transfer_amount, payment_code, reference_code,
    transaction_at, resolution_status, raw_payload
  ) VALUES (
    99000002, v_store, 'MB', '123456789', 'in',
    (v_quote->>'final_total')::numeric,
    'PILOTSAFE2', 'pilot-safety-2', now(), 'matched',
    jsonb_build_object('source', 'pilot_safety_test')
  ) RETURNING id INTO v_transaction;
  PERFORM direct_delivery_test.set_actor();
  PERFORM public.direct_order_staff_link_sepay(
    v_store, v_direct_request, v_transaction
  );
  v_approval := public.direct_order_approve_verified_payment(
    v_store, v_direct_request
  );
  v_order := (v_approval->>'order_id')::uuid;
  v_ticket := (v_approval->>'ticket_id')::uuid;

  IF NOT EXISTS (
    SELECT 1 FROM public.direct_order_financials financial
    WHERE financial.request_id = v_direct_request
      AND financial.delivery_payment_mode = 'customer_direct'
      AND financial.delivery_fee_total = 0
      AND financial.final_total = (v_quote->>'final_total')::numeric
  ) THEN
    RAISE EXCEPTION 'customer-direct financial snapshot is invalid';
  END IF;

  SELECT id INTO v_job_before
  FROM public.print_jobs
  WHERE order_id = v_order AND copy_type = 'receipt' AND batch_no = 1;
  IF v_job_before IS NULL THEN
    RAISE EXCEPTION 'customer bill was not automatically queued';
  END IF;

  INSERT INTO public.printer_destinations(
    restaurant_id, name, ip, port, purpose, is_active
  ) VALUES (
    v_store, 'Pilot customer bill printer', '192.168.10.25', 9100,
    'receipt', true
  );
  PERFORM direct_delivery_test.set_actor();
  v_approval := public.enqueue_direct_order_customer_receipt(
    v_store, v_direct_request, false
  );
  v_job_after := (v_approval->>'job_id')::uuid;
  IF v_job_after <> v_job_before
     OR v_approval->>'status' <> 'pending'
     OR (
       SELECT count(*) FROM public.print_jobs
       WHERE order_id = v_order AND copy_type = 'receipt' AND batch_no = 1
     ) <> 1 THEN
    RAISE EXCEPTION 'customer bill retry was not idempotent: %', v_approval;
  END IF;

  v_transition := public.direct_delivery_ticket_transition(
    v_store, v_ticket, 1, 'preparing'
  );
  v_transition := public.direct_delivery_ticket_transition(
    v_store, v_ticket, (v_transition->>'version')::integer, 'ready'
  );
  PERFORM public.direct_order_set_dispatch_with_payment_mode(
    v_store,
    v_direct_request,
    'https://grab.onelink.me/test/customer-direct',
    NULL
  );
  IF NOT EXISTS (
    SELECT 1 FROM public.direct_order_dispatches dispatch
    WHERE dispatch.request_id = v_direct_request
      AND dispatch.delivery_payment_mode = 'customer_direct'
      AND dispatch.customer_delivery_fee = 0
      AND dispatch.actual_grab_fee IS NULL
      AND dispatch.cash_paid_at IS NULL
      AND dispatch.fee_variance IS NULL
  ) OR NOT EXISTS (
    SELECT 1 FROM public.direct_delivery_fulfillment_tickets ticket
    WHERE ticket.id = v_ticket AND ticket.status = 'dispatched'
  ) THEN
    RAISE EXCEPTION 'customer-direct dispatch created a store cash payout';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.direct_order_financials financial
    WHERE financial.request_id = v_unverified_request
      AND financial.delivery_payment_mode = 'store_prepaid'
      AND financial.delivery_fee_total = 25000
  ) THEN
    RAISE EXCEPTION 'later quote changed the earlier order delivery fee';
  END IF;
END;
$contract$;

SELECT 'DIRECT_ORDER_PILOT_SAFETY_CONTRACT_PASS' AS result;
ROLLBACK;
