-- Customer VAT/history/proof retry and cashier completion contract.
-- Run only against a disposable codex_direct_* database.
\set ON_ERROR_STOP on
BEGIN;
\ir fixtures/direct_delivery_test_fixture.sql

DO $contract$
DECLARE
  v_fixture jsonb;
  v_store uuid;
  v_request uuid;
  v_session uuid;
  v_secret text;
  v_quote uuid;
  v_proof uuid;
  v_review jsonb;
  v_commit jsonb;
  v_replay jsonb;
  v_status jsonb;
  v_ticket uuid;
  v_transition jsonb;
  v_completion jsonb;
  v_completion_replay jsonb;
  v_blocked boolean := false;
  v_path text;
  v_menu uuid;
  v_payload jsonb;
  v_extra_one jsonb;
  v_extra_two jsonb;
  v_orders jsonb;
BEGIN
  v_fixture := direct_delivery_test.create_request('payment_review');
  v_store := (v_fixture->>'store_id')::uuid;
  v_request := (v_fixture->>'request_id')::uuid;
  v_session := (v_fixture->>'session_id')::uuid;
  v_secret := v_fixture->>'secret_hash';
  v_quote := (v_fixture->>'quote_id')::uuid;
  SELECT message.id INTO STRICT v_proof
  FROM public.direct_order_messages message
  WHERE message.request_id = v_request
    AND message.message_type = 'payment_proof';

  PERFORM direct_delivery_test.set_actor();
  v_review := public.direct_order_staff_request_proof_resubmission(
    v_store, v_request, v_proof, 'blurry', 'transaction number unreadable'
  );
  v_status := public.direct_order_public_status_v2(
    v_session, v_secret, v_request
  );
  IF v_status->'quote'->'vat_total' IS NULL
     OR v_status->'quote'->'menu_vat' IS NULL
     OR v_status->'proof_review'->>'id' <> v_review->>'id'
     OR (v_status->'proof_review'->>'can_resubmit')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'DIRECT_ORDER_V2_STATUS_CONTRACT_FAILED:%', v_status;
  END IF;

  BEGIN
    PERFORM public.direct_order_approve_payment(
      v_store, v_request, (v_fixture->>'final_total')::numeric, 'test-reference'
    );
  EXCEPTION WHEN OTHERS THEN
    v_blocked := SQLERRM LIKE '%DIRECT_ORDER_PROOF_RESUBMISSION_PENDING%';
  END;
  IF NOT v_blocked THEN
    RAISE EXCEPTION 'DIRECT_ORDER_APPROVAL_WAS_NOT_BLOCKED_DURING_REVIEW';
  END IF;

  v_path := v_store::text || '/' || v_request::text || '/'
    || gen_random_uuid()::text || '.jpg';
  v_commit := public.direct_order_public_commit_proof_v2(
    v_session, v_secret, v_request, v_quote, v_path,
    (v_review->>'id')::uuid
  );
  v_replay := public.direct_order_public_commit_proof_v2(
    v_session, v_secret, v_request, v_quote, v_path,
    (v_review->>'id')::uuid
  );
  IF (v_commit->>'idempotent')::boolean IS NOT FALSE
     OR (v_replay->>'idempotent')::boolean IS NOT TRUE
     OR v_commit->>'message_id' <> v_replay->>'message_id'
     OR NOT EXISTS (
       SELECT 1 FROM public.direct_order_proof_review_requests review
       WHERE review.id = (v_review->>'id')::uuid
         AND review.status = 'resubmitted'
         AND review.replacement_message_id = (v_commit->>'message_id')::uuid
     ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_PROOF_RETRY_CONTRACT_FAILED:%:%',
      v_commit, v_replay;
  END IF;

  PERFORM direct_delivery_test.set_actor();
  INSERT INTO public.direct_delivery_fulfillment_tickets(
    request_id, restaurant_id, pickup_code, status, version,
    dispatched_at, updated_by
  ) VALUES (
    v_request, v_store, v_fixture->>'reference_code', 'dispatched', 4,
    now(), (v_fixture->>'auth_id')::uuid
  ) RETURNING id, to_jsonb(direct_delivery_fulfillment_tickets)
    INTO v_ticket, v_transition;

  UPDATE public.users SET role = 'kitchen'
  WHERE auth_id = (v_fixture->>'auth_id')::uuid;
  PERFORM direct_delivery_test.set_actor();
  v_blocked := false;
  BEGIN
    PERFORM public.direct_delivery_ticket_transition(
      v_store, v_ticket, (v_transition->>'version')::integer, 'completed'
    );
  EXCEPTION WHEN OTHERS THEN
    v_blocked := SQLERRM LIKE '%DIRECT_ORDER_FORBIDDEN%';
  END;
  IF NOT v_blocked THEN
    RAISE EXCEPTION 'DIRECT_ORDER_KITCHEN_COMPLETION_WAS_NOT_BLOCKED';
  END IF;

  UPDATE public.users SET role = 'cashier'
  WHERE auth_id = (v_fixture->>'auth_id')::uuid;
  PERFORM direct_delivery_test.set_actor();
  v_completion := public.direct_order_cashier_complete_delivery(
    v_store, v_request, (v_transition->>'version')::integer
  );
  v_completion_replay := public.direct_order_cashier_complete_delivery(
    v_store, v_request, (v_transition->>'version')::integer
  );
  v_status := public.direct_order_public_status_v2(
    v_session, v_secret, v_request
  );
  IF v_completion->>'status' <> 'completed'
     OR (v_completion->>'idempotent')::boolean IS NOT FALSE
     OR (v_completion_replay->>'idempotent')::boolean IS NOT TRUE
     OR v_status->'fulfillment'->>'status' <> 'completed'
     OR v_status->'fulfillment'->>'completed_at' IS NULL
     OR (
       SELECT count(*) FROM public.direct_order_messages message
       WHERE message.request_id = v_request
         AND message.body = 'DIRECT_ORDER_DELIVERY_COMPLETED'
     ) <> 1 THEN
    RAISE EXCEPTION 'DIRECT_ORDER_CASHIER_COMPLETION_CONTRACT_FAILED:%:%',
      v_completion, v_completion_replay;
  END IF;

  SELECT menu_item_id INTO STRICT v_menu
  FROM direct_delivery_test.constants LIMIT 1;
  v_payload := jsonb_build_object(
    'locale', 'vi',
    'items', jsonb_build_array(jsonb_build_object(
      'menu_item_id', v_menu, 'quantity', 1, 'note', null
    )),
    'address', jsonb_build_object(
      'customer_name', 'Multi Order Customer',
      'customer_phone', '+84901234567',
      'formatted_address', '123 Nguyen Hue, District 1, HCMC',
      'detail_address', 'Floor 4, room 401',
      'latitude', 10.775,
      'longitude', 106.704,
      'google_place_id', 'test-place-id',
      'district', 'District 1',
      'ward', 'Ben Nghe',
      'address_source', 'search',
      'location_verified', true
    )
  );
  v_extra_one := public.direct_order_public_submit(
    v_session, v_secret, gen_random_uuid(), v_payload
  );
  v_extra_two := public.direct_order_public_submit(
    v_session, v_secret, gen_random_uuid(), v_payload
  );
  v_orders := public.direct_order_public_orders_v2(v_session, v_secret, 50);
  IF jsonb_array_length(v_orders) < 3
     OR NOT EXISTS (
       SELECT 1 FROM jsonb_array_elements(v_orders) row_value
       WHERE row_value->>'request_id' = v_extra_one->>'request_id'
     )
     OR NOT EXISTS (
       SELECT 1 FROM jsonb_array_elements(v_orders) row_value
       WHERE row_value->>'request_id' = v_extra_two->>'request_id'
     ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_MULTI_ORDER_HISTORY_CONTRACT_FAILED:%',
      v_orders;
  END IF;

  IF has_table_privilege(
       'anon', 'public.direct_order_proof_review_requests', 'SELECT'
     )
     OR NOT has_table_privilege(
       'service_role', 'public.direct_order_proof_review_requests',
       'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER'
     )
     OR has_function_privilege(
       'anon',
       'public.direct_order_public_status_v2(uuid,text,uuid)',
       'EXECUTE'
     ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_V2_PRIVILEGE_CONTRACT_FAILED';
  END IF;
END;
$contract$;

SELECT 'DIRECT_ORDER_CUSTOMER_PAYMENT_STATUS_CONTRACT_PASS' AS result;

ROLLBACK;
