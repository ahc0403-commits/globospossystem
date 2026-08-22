-- Persisted request/quote/ticket state contract. Disposable DB only.
\set ON_ERROR_STOP on
BEGIN;
\ir fixtures/direct_delivery_test_fixture.sql

CREATE TEMP TABLE _direct_state_results (
  scenario text PRIMARY KEY,
  ok boolean NOT NULL,
  detail text
);

DO $contract$
DECLARE
  v_fixture jsonb;
  v_request uuid;
  v_store uuid;
  v_total numeric;
  v_first_quote uuid;
  v_second_quote jsonb;
  v_approval jsonb;
  v_replay jsonb;
  v_ticket uuid;
  v_transition jsonb;
  v_version integer;
  v_blocked boolean;
BEGIN
  -- Initial state and re-quote versioning.
  v_fixture := direct_delivery_test.create_request('awaiting_quote');
  v_request := (v_fixture->>'request_id')::uuid;
  v_store := (v_fixture->>'store_id')::uuid;
  INSERT INTO _direct_state_results VALUES (
    'submit enters awaiting_quote with zero legacy graph',
    EXISTS (SELECT 1 FROM public.direct_order_requests
            WHERE id=v_request AND state='awaiting_quote')
      AND NOT EXISTS (SELECT 1 FROM public.direct_order_financials
                      WHERE request_id=v_request)
      AND NOT EXISTS (SELECT 1 FROM public.direct_delivery_fulfillment_tickets
                      WHERE request_id=v_request),
    'direct rows only before approval'
  );

  PERFORM direct_delivery_test.set_actor();
  v_second_quote := public.direct_order_staff_quote(
    v_store, v_request, 20000, 'first quote'
  );
  v_first_quote := (v_second_quote->>'id')::uuid;
  v_second_quote := public.direct_order_staff_quote(
    v_store, v_request, 25000, 'replacement quote'
  );
  INSERT INTO _direct_state_results VALUES (
    'quote and requote preserve one live version',
    EXISTS (SELECT 1 FROM public.direct_order_requests
            WHERE id=v_request AND state='quoted')
      AND EXISTS (SELECT 1 FROM public.direct_order_quotes
                  WHERE id=v_first_quote AND version=1 AND status='superseded')
      AND EXISTS (SELECT 1 FROM public.direct_order_quotes
                  WHERE id=(v_second_quote->>'id')::uuid
                    AND version=2 AND status='active')
      AND (SELECT count(*) FROM public.direct_order_quotes
           WHERE request_id=v_request AND status IN ('active','locked'))=1,
    'version 1 superseded, version 2 active'
  );

  PERFORM direct_delivery_test.cancel(v_request);
  v_blocked := false;
  BEGIN
    PERFORM direct_delivery_test.cancel(v_request);
  EXCEPTION WHEN OTHERS THEN
    v_blocked := SQLERRM LIKE '%DIRECT_ORDER_REQUEST_NOT_CANCELLABLE%';
  END;
  INSERT INTO _direct_state_results VALUES (
    'customer cancel is terminal and expires the live quote',
    v_blocked
      AND EXISTS (SELECT 1 FROM public.direct_order_requests
                  WHERE id=v_request AND state='cancelled')
      AND EXISTS (SELECT 1 FROM public.direct_order_quotes
                  WHERE request_id=v_request AND version=2 AND status='expired')
      AND NOT EXISTS (SELECT 1 FROM public.direct_order_financials
                      WHERE request_id=v_request),
    'cancel replay rejected without financial writes'
  );

  -- Proof locks the quote; reject is terminal and cannot approve.
  v_fixture := direct_delivery_test.create_request('payment_review');
  v_request := (v_fixture->>'request_id')::uuid;
  v_total := (v_fixture->>'final_total')::numeric;
  INSERT INTO _direct_state_results VALUES (
    'proof enters payment review and locks quote without approval',
    EXISTS (SELECT 1 FROM public.direct_order_requests
            WHERE id=v_request AND state='awaiting_payment_review')
      AND EXISTS (SELECT 1 FROM public.direct_order_quotes
                  WHERE request_id=v_request AND status='locked')
      AND NOT EXISTS (SELECT 1 FROM public.direct_order_financials
                      WHERE request_id=v_request),
    'proof and SePay evidence cannot auto-approve'
  );

  v_blocked := false;
  PERFORM direct_delivery_test.set_actor();
  BEGIN
    PERFORM public.direct_order_staff_quote(v_store, v_request, 30000, NULL);
  EXCEPTION WHEN OTHERS THEN
    v_blocked := SQLERRM LIKE '%DIRECT_ORDER_REQUEST_NOT_QUOTABLE%';
  END;
  INSERT INTO _direct_state_results VALUES (
    'payment review cannot be silently requoted',
    v_blocked,
    'locked proof quote is stable'
  );

  PERFORM direct_delivery_test.reject(v_request);
  v_blocked := false;
  BEGIN
    PERFORM direct_delivery_test.approve(v_request, v_total);
  EXCEPTION WHEN OTHERS THEN
    v_blocked := SQLERRM LIKE '%DIRECT_ORDER_REQUEST_NOT_APPROVABLE%';
  END;
  INSERT INTO _direct_state_results VALUES (
    'cashier rejection is terminal and wins before approval',
    v_blocked
      AND EXISTS (SELECT 1 FROM public.direct_order_requests
                  WHERE id=v_request AND state='rejected')
      AND EXISTS (SELECT 1 FROM public.direct_order_quotes
                  WHERE request_id=v_request AND status='expired')
      AND NOT EXISTS (SELECT 1 FROM public.direct_order_financials
                      WHERE request_id=v_request),
    'later approval rejected and graph remains empty'
  );

  -- Manual approval and identical replay.
  v_fixture := direct_delivery_test.create_request('payment_review');
  v_request := (v_fixture->>'request_id')::uuid;
  v_total := (v_fixture->>'final_total')::numeric;
  v_approval := direct_delivery_test.approve(v_request, v_total);
  v_replay := direct_delivery_test.approve(v_request, v_total);
  PERFORM direct_delivery_test.assert_single_graph(v_request);
  INSERT INTO _direct_state_results VALUES (
    'manual approval creates one graph and replay returns its identity',
    (v_approval->>'idempotent')::boolean=false
      AND (v_replay->>'idempotent')::boolean=true
      AND v_approval->>'order_id'=v_replay->>'order_id'
      AND v_approval->>'payment_id'=v_replay->>'payment_id'
      AND v_approval->>'ticket_id'=v_replay->>'ticket_id'
      AND EXISTS (SELECT 1 FROM public.direct_order_requests
                  WHERE id=v_request AND state='approved'),
    'single order/payment/ticket identity'
  );

  -- Ticket version and full happy path, including dispatch auto-transition.
  v_ticket := (v_approval->>'ticket_id')::uuid;
  PERFORM direct_delivery_test.set_actor();
  v_transition := public.direct_delivery_ticket_transition(
    v_store, v_ticket, 1, 'preparing'
  );
  v_version := (v_transition->>'version')::integer;
  v_blocked := false;
  BEGIN
    PERFORM public.direct_delivery_ticket_transition(
      v_store, v_ticket, 1, 'ready'
    );
  EXCEPTION WHEN OTHERS THEN
    v_blocked := SQLERRM LIKE '%DIRECT_DELIVERY_TICKET_VERSION_CONFLICT%';
  END;
  v_transition := public.direct_delivery_ticket_transition(
    v_store, v_ticket, v_version, 'ready'
  );
  PERFORM public.direct_order_set_dispatch(
    v_store, v_request, 'https://grab.com/track/direct-state-test', 30000
  );
  SELECT version INTO v_version
  FROM public.direct_delivery_fulfillment_tickets WHERE id=v_ticket;
  v_transition := public.direct_delivery_ticket_transition(
    v_store, v_ticket, v_version, 'completed'
  );
  INSERT INTO _direct_state_results VALUES (
    'ticket optimistic lock and dispatch lifecycle are monotonic',
    v_blocked
      AND v_transition->>'status'='completed'
      AND EXISTS (SELECT 1 FROM public.direct_order_dispatches
                  WHERE request_id=v_request AND fee_variance=-5000)
      AND EXISTS (SELECT 1 FROM public.direct_order_requests
                  WHERE id=v_request AND state='approved'),
    'pending-preparing-ready-dispatched-completed; request stays approved'
  );

  v_blocked := false;
  BEGIN
    PERFORM public.direct_delivery_ticket_transition(
      v_store, v_ticket, (v_transition->>'version')::integer, 'ready'
    );
  EXCEPTION WHEN OTHERS THEN
    v_blocked := SQLERRM LIKE '%DIRECT_DELIVERY_TICKET_TRANSITION_INVALID%';
  END;
  INSERT INTO _direct_state_results VALUES (
    'completed ticket is terminal',
    v_blocked,
    'no terminal regression'
  );

  -- Cancellation branch of direct ticket state machine.
  v_fixture := direct_delivery_test.create_request('payment_review');
  v_request := (v_fixture->>'request_id')::uuid;
  v_total := (v_fixture->>'final_total')::numeric;
  v_approval := direct_delivery_test.approve(v_request, v_total);
  v_ticket := (v_approval->>'ticket_id')::uuid;
  PERFORM direct_delivery_test.set_actor();
  v_transition := public.direct_delivery_ticket_transition(
    v_store, v_ticket, 1, 'cancelled'
  );
  v_blocked := false;
  BEGIN
    PERFORM public.direct_delivery_ticket_transition(
      v_store, v_ticket, (v_transition->>'version')::integer, 'preparing'
    );
  EXCEPTION WHEN OTHERS THEN
    v_blocked := SQLERRM LIKE '%DIRECT_DELIVERY_TICKET_TRANSITION_INVALID%';
  END;
  INSERT INTO _direct_state_results VALUES (
    'cancelled direct ticket is terminal',
    v_blocked AND v_transition->>'status'='cancelled',
    'pending-cancelled allowed; no later transition'
  );

  -- Dispatch is impossible without manual approval.
  v_fixture := direct_delivery_test.create_request('quoted');
  v_request := (v_fixture->>'request_id')::uuid;
  v_blocked := false;
  PERFORM direct_delivery_test.set_actor();
  BEGIN
    PERFORM public.direct_order_set_dispatch(
      v_store, v_request, 'https://grab.com/track/not-approved', 25000
    );
  EXCEPTION WHEN OTHERS THEN
    v_blocked := SQLERRM LIKE '%DIRECT_ORDER_NOT_APPROVED%';
  END;
  INSERT INTO _direct_state_results VALUES (
    'Grab link cannot precede manual approval',
    v_blocked
      AND NOT EXISTS (SELECT 1 FROM public.direct_order_dispatches
                      WHERE request_id=v_request),
    'dispatch has an approved-financial prerequisite'
  );
END;
$contract$;

DO $assert$
DECLARE v_failures text;
BEGIN
  SELECT string_agg(scenario || ': ' || detail, E'\n' ORDER BY scenario)
  INTO v_failures FROM _direct_state_results WHERE NOT ok;
  IF v_failures IS NOT NULL THEN
    RAISE EXCEPTION E'DIRECT_DELIVERY_STATE_CONTRACT_FAILED:\n%', v_failures;
  END IF;
END;
$assert$;

SELECT scenario, detail FROM _direct_state_results ORDER BY scenario;
ROLLBACK;
