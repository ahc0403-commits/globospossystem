-- Driver receipt lifecycle and isolation. Disposable codex_direct_* DB only.
\set ON_ERROR_STOP on

BEGIN;

\ir fixtures/direct_delivery_test_fixture.sql

CREATE TEMP TABLE _driver_receipt_results (
  scenario text PRIMARY KEY,
  ok boolean NOT NULL,
  detail text
);

DO $contract$
DECLARE
  v_fixture jsonb;
  v_no_destination_fixture jsonb;
  v_no_destination_first jsonb;
  v_no_destination_retry jsonb;
  v_unapproved_fixture jsonb;
  v_approval jsonb;
  v_first jsonb;
  v_replay jsonb;
  v_reprint jsonb;
  v_reprint_replay jsonb;
  v_reprint_retry jsonb;
  v_status jsonb;
  v_payload jsonb;
  v_request uuid;
  v_store uuid;
  v_auth uuid;
  v_order uuid;
  v_first_job uuid;
  v_no_destination_job uuid;
  v_no_destination_error text;
  v_reprint_job uuid;
  v_customer_receipts_before integer;
  v_customer_receipts_after integer;
  v_cleanup_count integer;
  v_generic_reprint_blocked boolean := false;
  v_kitchen_enqueue_blocked boolean := false;
  v_kitchen_status_blocked boolean := false;
  v_wrong_store_blocked boolean := false;
  v_missing_address_error text;
  v_unapproved_error text;
BEGIN
  v_fixture := direct_delivery_test.create_request('payment_review');
  v_request := (v_fixture->>'request_id')::uuid;
  v_store := (v_fixture->>'store_id')::uuid;
  v_auth := (v_fixture->>'auth_id')::uuid;
  v_approval := direct_delivery_test.approve(
    v_request,
    (v_fixture->>'final_total')::numeric
  );
  v_order := (v_approval->>'order_id')::uuid;

  INSERT INTO public.printer_destinations(
    restaurant_id, name, ip, port, purpose, is_active
  ) VALUES (
    v_store, 'Driver receipt test printer', '192.168.10.20', 9100,
    'receipt', true
  );

  SELECT count(*)
  INTO v_customer_receipts_before
  FROM public.print_jobs job
  WHERE job.order_id = v_order
    AND job.copy_type = 'receipt';

  PERFORM direct_delivery_test.set_actor();
  v_first := public.enqueue_direct_delivery_driver_receipt(
    v_store, v_request, false
  );
  v_replay := public.enqueue_direct_delivery_driver_receipt(
    v_store, v_request, false
  );
  v_first_job := (v_first->>'job_id')::uuid;

  SELECT job.payload
  INTO v_payload
  FROM public.print_jobs job
  WHERE job.id = v_first_job;

  INSERT INTO _driver_receipt_results VALUES (
    'first driver receipt contains exact address and charged Grab total once',
    (v_first->>'batch_no')::integer = 1
      AND (v_replay->>'job_id')::uuid = v_first_job
      AND (v_replay->>'idempotent')::boolean
      AND v_payload->>'ticket' = 'delivery_driver_receipt'
      AND v_payload->>'customer_name' = 'Test Customer'
      AND v_payload->>'customer_phone' = '+84901234567'
      AND v_payload->>'formatted_address' =
        '123 Nguyen Hue, District 1, HCMC'
      AND v_payload->>'detail_address' = 'Floor 4, room 401'
      AND (v_payload->>'delivery_fee_total')::numeric = 25000
      AND (v_payload->>'final_total')::numeric =
        (v_payload->>'menu_total')::numeric
        + (v_payload->>'service_charge_total')::numeric
        + (v_payload->>'delivery_fee_total')::numeric
      AND (v_payload->>'customer_due')::numeric = 0
      AND NOT (v_payload ? 'actual_grab_fee')
      AND NOT (v_payload ? 'fee_variance')
      AND jsonb_array_length(v_payload->'items') = 1,
    v_payload::text
  );

  UPDATE public.print_jobs
  SET status = 'done', updated_at = now()
  WHERE id = v_first_job;

  SELECT job.payload
  INTO v_payload
  FROM public.print_jobs job
  WHERE job.id = v_first_job;
  v_status := public.direct_order_driver_receipt_status(v_store, v_request);

  INSERT INTO _driver_receipt_results VALUES (
    'completed driver receipt redacts PII and becomes reprintable',
    NOT (v_payload ? 'customer_name')
      AND NOT (v_payload ? 'customer_phone')
      AND NOT (v_payload ? 'formatted_address')
      AND NOT (v_payload ? 'detail_address')
      AND (v_payload->>'pii_redacted')::boolean
      AND (v_status->>'exists')::boolean
      AND v_status->>'status' = 'done'
      AND (v_status->>'can_reprint')::boolean,
    format('payload=%s status=%s', v_payload, v_status)
  );

  -- Cashiers are already blocked by the legacy reprint authorization check.
  -- Exercise an authorized legacy caller so the driver-only insert guard is
  -- proven to be the final boundary as well.
  UPDATE public.users
  SET role = 'admin'
  WHERE auth_id = v_auth;
  PERFORM direct_delivery_test.set_actor();
  BEGIN
    PERFORM public.reprint_print_job(v_first_job);
  EXCEPTION WHEN OTHERS THEN
    v_generic_reprint_blocked :=
      SQLERRM = 'DIRECT_ORDER_DRIVER_RECEIPT_USE_DEDICATED_REPRINT';
  END;
  INSERT INTO _driver_receipt_results VALUES (
    'generic reprint cannot bypass the dedicated driver receipt path',
    v_generic_reprint_blocked
      AND (SELECT count(*) FROM public.print_jobs job
           WHERE job.order_id = v_order
             AND job.copy_type = 'delivery_driver_receipt') = 1,
    'generic reprint must not copy redacted PII or route to kitchen'
  );

  v_reprint := public.enqueue_direct_delivery_driver_receipt(
    v_store, v_request, true
  );
  v_reprint_job := (v_reprint->>'job_id')::uuid;
  v_reprint_replay := public.enqueue_direct_delivery_driver_receipt(
    v_store, v_request, true
  );

  UPDATE public.users
  SET role = 'cashier'
  WHERE auth_id = v_auth;
  PERFORM direct_delivery_test.set_actor();

  SELECT job.payload
  INTO v_payload
  FROM public.print_jobs job
  WHERE job.id = v_reprint_job;

  INSERT INTO _driver_receipt_results VALUES (
    'explicit reprint rebuilds current source snapshot in the next batch',
    (v_reprint->>'batch_no')::integer = 2
      AND v_reprint_job <> v_first_job
      AND (v_reprint_replay->>'job_id')::uuid = v_reprint_job
      AND (v_reprint_replay->>'idempotent')::boolean
      AND v_payload->>'formatted_address' =
        '123 Nguyen Hue, District 1, HCMC'
      AND (SELECT count(*) FROM public.print_jobs job
           WHERE job.order_id = v_order
             AND job.copy_type = 'delivery_driver_receipt') = 2,
    v_reprint::text
  );

  UPDATE public.printer_destinations
  SET is_active = false
  WHERE restaurant_id = v_store
    AND purpose = 'receipt';
  v_no_destination_fixture := direct_delivery_test.create_request(
    'payment_review'
  );
  PERFORM direct_delivery_test.approve(
    (v_no_destination_fixture->>'request_id')::uuid,
    (v_no_destination_fixture->>'final_total')::numeric
  );
  PERFORM direct_delivery_test.set_actor();
  v_no_destination_first := public.enqueue_direct_delivery_driver_receipt(
    v_store,
    (v_no_destination_fixture->>'request_id')::uuid,
    false
  );
  v_no_destination_job := (v_no_destination_first->>'job_id')::uuid;
  SELECT last_error
  INTO v_no_destination_error
  FROM public.print_jobs
  WHERE id = v_no_destination_job;

  UPDATE public.printer_destinations
  SET is_active = true
  WHERE restaurant_id = v_store
    AND purpose = 'receipt';
  v_no_destination_retry := public.enqueue_direct_delivery_driver_receipt(
    v_store,
    (v_no_destination_fixture->>'request_id')::uuid,
    false
  );

  INSERT INTO _driver_receipt_results VALUES (
    'missing receipt destination fails safely and retry reuses batch one',
    v_no_destination_first->>'status' = 'failed'
      AND v_no_destination_error = 'NO_DESTINATION'
      AND (SELECT last_error FROM public.print_jobs
           WHERE id = v_no_destination_job) IS NULL
      AND (v_no_destination_retry->>'job_id')::uuid = v_no_destination_job
      AND (v_no_destination_retry->>'batch_no')::integer = 1
      AND v_no_destination_retry->>'status' = 'pending',
    format(
      'first=%s retry=%s current_error=%s',
      v_no_destination_first,
      v_no_destination_retry,
      v_no_destination_error
    )
  );

  BEGIN
    PERFORM public.direct_order_driver_receipt_status(
      gen_random_uuid(),
      v_request
    );
  EXCEPTION WHEN OTHERS THEN
    v_wrong_store_blocked := true;
  END;

  INSERT INTO _driver_receipt_results VALUES (
    'store scope blocks a request through an unrelated store id',
    v_wrong_store_blocked,
    'direct_order_require_actor must run before request lookup'
  );

  UPDATE public.users
  SET role = 'kitchen'
  WHERE auth_id = v_auth;
  BEGIN
    PERFORM public.direct_order_driver_receipt_status(v_store, v_request);
  EXCEPTION WHEN OTHERS THEN
    v_kitchen_status_blocked := true;
  END;
  BEGIN
    PERFORM public.enqueue_direct_delivery_driver_receipt(
      v_store,
      v_request,
      false
    );
  EXCEPTION WHEN OTHERS THEN
    v_kitchen_enqueue_blocked := true;
  END;
  UPDATE public.users
  SET role = 'cashier'
  WHERE auth_id = v_auth;
  PERFORM direct_delivery_test.set_actor();

  INSERT INTO _driver_receipt_results VALUES (
    'kitchen role cannot inspect or enqueue the cashier driver receipt',
    v_kitchen_status_blocked AND v_kitchen_enqueue_blocked,
    'direct_order_require_actor must remain the authorization boundary'
  );

  UPDATE public.print_jobs
  SET status = 'failed',
      last_error = 'TEST_PRINT_FAILURE',
      updated_at = now()
  WHERE id = v_reprint_job;
  v_status := public.direct_order_driver_receipt_status(v_store, v_request);
  v_reprint_retry := public.enqueue_direct_delivery_driver_receipt(
    v_store, v_request, true
  );

  INSERT INTO _driver_receipt_results VALUES (
    'failed reprint retry reuses its batch while a completed copy remains',
    v_status->>'status' = 'failed'
      AND (v_status->>'can_reprint')::boolean
      AND (v_reprint_retry->>'job_id')::uuid = v_reprint_job
      AND (v_reprint_retry->>'batch_no')::integer = 2
      AND (v_reprint_retry->>'idempotent')::boolean
      AND v_reprint_retry->>'status' = 'pending'
      AND (SELECT count(*) FROM public.print_jobs job
           WHERE job.order_id = v_order
             AND job.copy_type = 'delivery_driver_receipt') = 2,
    format('status=%s retry=%s', v_status, v_reprint_retry)
  );

  UPDATE public.print_jobs
  SET status = 'failed',
      created_at = now() - interval '25 hours',
      updated_at = now() - interval '25 hours'
  WHERE id = v_reprint_job;
  v_status := public.direct_order_driver_receipt_status(v_store, v_request);
  v_cleanup_count := public.cleanup_expired_delivery_driver_receipt_jobs();

  SELECT job.payload
  INTO v_payload
  FROM public.print_jobs job
  WHERE job.id = v_reprint_job;

  INSERT INTO _driver_receipt_results VALUES (
    'expired failed driver receipt is cancelled and PII-redacted',
    v_status->>'status' = 'failed'
      AND (v_status->>'can_reprint')::boolean
      AND v_cleanup_count = 1
      AND (SELECT status FROM public.print_jobs WHERE id = v_reprint_job) =
        'cancelled'
      AND NOT (v_payload ? 'customer_name')
      AND NOT (v_payload ? 'customer_phone')
      AND NOT (v_payload ? 'formatted_address')
      AND NOT (v_payload ? 'detail_address'),
    format('cleanup=%s payload=%s', v_cleanup_count, v_payload)
  );

  DELETE FROM public.direct_order_request_addresses address
  WHERE address.request_id = v_request;
  BEGIN
    PERFORM public.enqueue_direct_delivery_driver_receipt(
      v_store, v_request, true
    );
  EXCEPTION WHEN OTHERS THEN
    v_missing_address_error := SQLERRM;
  END;

  SELECT count(*)
  INTO v_customer_receipts_after
  FROM public.print_jobs job
  WHERE job.order_id = v_order
    AND job.copy_type = 'receipt';

  INSERT INTO _driver_receipt_results VALUES (
    'driver printing remains isolated from customer receipt and payment graph',
    v_missing_address_error =
        'DIRECT_ORDER_DRIVER_RECEIPT_ADDRESS_UNAVAILABLE'
      AND v_customer_receipts_after = v_customer_receipts_before
      AND EXISTS (
        SELECT 1 FROM public.orders order_row
        WHERE order_row.id = v_order
          AND order_row.status = 'completed'
      )
      AND (SELECT count(*) FROM public.payments payment
           WHERE payment.order_id = v_order) = 1
      AND (SELECT count(*) FROM public.direct_order_financials financial
           WHERE financial.request_id = v_request) = 1
      AND (SELECT count(*)
           FROM public.direct_delivery_fulfillment_tickets ticket
           WHERE ticket.request_id = v_request) = 1,
    format(
      'error=%s customer_receipts=%s/%s',
      v_missing_address_error,
      v_customer_receipts_before,
      v_customer_receipts_after
    )
  );

  v_unapproved_fixture := direct_delivery_test.create_request(
    'payment_review'
  );
  PERFORM direct_delivery_test.set_actor();
  BEGIN
    PERFORM public.enqueue_direct_delivery_driver_receipt(
      v_store,
      (v_unapproved_fixture->>'request_id')::uuid,
      false
    );
  EXCEPTION WHEN OTHERS THEN
    v_unapproved_error := SQLERRM;
  END;

  INSERT INTO _driver_receipt_results VALUES (
    'unapproved direct order cannot enqueue a driver receipt',
    v_unapproved_error = 'DIRECT_ORDER_NOT_APPROVED',
    COALESCE(v_unapproved_error, 'no error')
  );
END;
$contract$;

DO $assert$
DECLARE
  v_failures text;
BEGIN
  SELECT string_agg(scenario || ': ' || detail, E'\n' ORDER BY scenario)
  INTO v_failures
  FROM _driver_receipt_results
  WHERE NOT ok;

  IF v_failures IS NOT NULL THEN
    RAISE EXCEPTION E'DIRECT_DELIVERY_DRIVER_RECEIPT_FAILED:\n%', v_failures;
  END IF;
END;
$assert$;

SELECT 'DIRECT_DELIVERY_DRIVER_RECEIPT_PASS' AS result,
       count(*) AS scenarios
FROM _driver_receipt_results;

ROLLBACK;
