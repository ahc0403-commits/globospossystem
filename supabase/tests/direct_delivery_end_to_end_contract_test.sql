-- Full direct-delivery operational graph. Disposable codex_direct_* DB only.
\set ON_ERROR_STOP on
BEGIN;
\ir fixtures/direct_delivery_test_fixture.sql

CREATE TEMP TABLE _direct_e2e_results (
  scenario text PRIMARY KEY,
  ok boolean NOT NULL,
  detail text
);

DO $contract$
DECLARE
  v_fixture jsonb;
  v_request uuid;
  v_store uuid;
  v_ticket uuid;
  v_order uuid;
  v_payment uuid;
  v_transition jsonb;
  v_status jsonb;
  v_analytics jsonb;
BEGIN
  v_fixture := direct_delivery_test.create_request('payment_review');
  v_request := (v_fixture->>'request_id')::uuid;
  v_store := (v_fixture->>'store_id')::uuid;

  PERFORM public.direct_order_public_message(
    (v_fixture->>'session_id')::uuid,
    v_fixture->>'secret_hash',
    v_request,
    'Please confirm the fourth-floor address.'
  );
  PERFORM direct_delivery_test.set_actor();
  PERFORM public.direct_order_staff_message(
    v_store,
    v_request,
    'Địa chỉ đã được xác nhận.'
  );

  v_status := direct_delivery_test.approve(
    v_request,
    (v_fixture->>'final_total')::numeric
  );
  v_ticket := (v_status->>'ticket_id')::uuid;
  v_order := (v_status->>'order_id')::uuid;
  v_payment := (v_status->>'payment_id')::uuid;

  PERFORM direct_delivery_test.set_actor();
  v_transition := public.direct_delivery_ticket_transition(
    v_store, v_ticket, 1, 'preparing'
  );
  v_transition := public.direct_delivery_ticket_transition(
    v_store, v_ticket, (v_transition->>'version')::integer, 'ready'
  );
  PERFORM public.direct_order_set_dispatch(
    v_store,
    v_request,
    'https://grab.onelink.me/test/direct-order-e2e',
    30000
  );
  SELECT to_jsonb(ticket) - ARRAY['restaurant_id', 'updated_by']
  INTO v_transition
  FROM public.direct_delivery_fulfillment_tickets ticket
  WHERE ticket.id=v_ticket;
  v_transition := public.direct_delivery_ticket_transition(
    v_store,
    v_ticket,
    (v_transition->>'version')::integer,
    'completed'
  );

  v_status := public.direct_order_public_status(
    (v_fixture->>'session_id')::uuid,
    v_fixture->>'secret_hash',
    v_request
  );
  UPDATE public.users
  SET role='admin'
  WHERE auth_id=(v_fixture->>'auth_id')::uuid;
  v_analytics := public.direct_order_analytics(
    v_store,
    (now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date,
    (now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date
  );

  INSERT INTO _direct_e2e_results VALUES (
    'request quote proof manual approval kitchen grab completion analytics',
    (v_status->>'state')='approved'
    AND (v_status->'fulfillment'->>'status')='completed'
    AND (v_status->'dispatch'->>'grab_tracking_url')=
      'https://grab.onelink.me/test/direct-order-e2e'
    AND EXISTS (
      SELECT 1 FROM public.orders order_row
      WHERE order_row.id=v_order
        AND order_row.sales_channel='delivery'
        AND order_row.status='completed'
    )
    AND EXISTS (
      SELECT 1 FROM public.payments payment
      WHERE payment.id=v_payment
        AND payment.order_id=v_order
        AND payment.method='BANKTRANSFER'
    )
    AND EXISTS (
      SELECT 1 FROM public.direct_order_financials financial
      WHERE financial.request_id=v_request
        AND financial.order_id=v_order
        AND financial.payment_id=v_payment
        AND financial.final_total=(v_fixture->>'final_total')::numeric
    )
    AND EXISTS (
      SELECT 1 FROM public.direct_order_dispatches dispatch
      WHERE dispatch.request_id=v_request
        AND dispatch.actual_grab_fee=30000
        AND dispatch.fee_variance=dispatch.customer_delivery_fee-30000
    )
    AND EXISTS (
      SELECT 1 FROM public.direct_order_messages message
      WHERE message.request_id=v_request
        AND message.sender_type='customer'
        AND message.body='Please confirm the fourth-floor address.'
    )
    AND EXISTS (
      SELECT 1 FROM public.direct_order_messages message
      WHERE message.request_id=v_request
        AND message.sender_type='cashier'
        AND message.body='Địa chỉ đã được xác nhận.'
    )
    AND (v_analytics->'summary'->>'order_count')::integer=1
    AND (SELECT count(*) FROM public.direct_order_financials
         WHERE request_id=v_request)=1
    AND (SELECT count(*) FROM public.direct_delivery_fulfillment_tickets
         WHERE request_id=v_request)=1,
    'one rollback-safe graph must cover every operational boundary'
  );
END;
$contract$;

DO $assert$
DECLARE v_failures text;
BEGIN
  SELECT string_agg(scenario || ': ' || detail, E'\n' ORDER BY scenario)
  INTO v_failures
  FROM _direct_e2e_results WHERE NOT ok;
  IF v_failures IS NOT NULL THEN
    RAISE EXCEPTION E'DIRECT_DELIVERY_E2E_FAILED:\n%', v_failures;
  END IF;
END;
$assert$;

SELECT 'DIRECT_DELIVERY_E2E_PASS' AS result,
       count(*) AS scenarios
FROM _direct_e2e_results;

ROLLBACK;
