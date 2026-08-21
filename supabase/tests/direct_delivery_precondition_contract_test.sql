-- Manual approval amount and operational precondition matrix.
\set ON_ERROR_STOP on

BEGIN;

\ir fixtures/direct_delivery_test_fixture.sql

CREATE TEMP TABLE _direct_precondition_results (
  scenario text PRIMARY KEY,
  ok boolean NOT NULL,
  detail text
);

CREATE OR REPLACE FUNCTION direct_delivery_test.graph_is_empty(
  p_request_id uuid
) RETURNS boolean
LANGUAGE sql
STABLE
AS $function$
  SELECT NOT EXISTS (
      SELECT 1 FROM public.direct_order_financials financial
      WHERE financial.request_id = p_request_id
    )
    AND NOT EXISTS (
      SELECT 1 FROM public.direct_delivery_fulfillment_tickets ticket
      WHERE ticket.request_id = p_request_id
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.orders order_row
      JOIN public.direct_order_requests request_row
        ON order_row.notes = 'Direct delivery ' || request_row.reference_code
      WHERE request_row.id = p_request_id
    )
$function$;

CREATE OR REPLACE FUNCTION direct_delivery_test.expect_approval_error(
  p_request_id uuid,
  p_amount numeric,
  p_expected text
) RETURNS boolean
LANGUAGE plpgsql
AS $function$
DECLARE v_error text;
BEGIN
  BEGIN
    PERFORM direct_delivery_test.approve(p_request_id, p_amount);
  EXCEPTION WHEN OTHERS THEN
    v_error := SQLERRM;
  END;
  RETURN v_error = p_expected
    AND direct_delivery_test.graph_is_empty(p_request_id);
END;
$function$;

DO $contract$
DECLARE
  v_fixture jsonb;
  v_store uuid;
  v_auth uuid;
  v_user uuid;
  v_menu uuid;
  v_request uuid;
  v_session uuid;
  v_secret text;
  v_total numeric;
  v_ok boolean;
  v_error text;
  v_result jsonb;
  v_kitchen_auth uuid := 'de200000-0000-4000-8000-000000000001';
  v_kitchen_user uuid := 'de200000-0000-4000-8000-000000000002';
BEGIN
  SELECT store_id, auth_id, user_id, menu_item_id
  INTO v_store, v_auth, v_user, v_menu
  FROM direct_delivery_test.constants
  LIMIT 1;

  INSERT INTO auth.users(id, email)
  VALUES (v_kitchen_auth, 'direct.delivery.kitchen.guard@globos.test');
  INSERT INTO public.users(
    id, auth_id, restaurant_id, role, full_name, is_active
  ) VALUES (
    v_kitchen_user, v_kitchen_auth, v_store, 'kitchen',
    'Direct Delivery Guard Kitchen', true
  );
  INSERT INTO public.user_store_access(
    user_id, store_id, is_primary, is_active, source_type
  ) VALUES (v_kitchen_user, v_store, true, true, 'direct');

  -- Exact amount succeeds and creates one graph.
  v_fixture := direct_delivery_test.create_request('payment_review');
  v_request := (v_fixture->>'request_id')::uuid;
  v_total := (v_fixture->>'final_total')::numeric;
  v_result := direct_delivery_test.approve(v_request, v_total);
  PERFORM direct_delivery_test.assert_single_graph(v_request);
  INSERT INTO _direct_precondition_results VALUES (
    'exact confirmed amount is accepted',
    COALESCE((v_result->>'idempotent')::boolean, true) = false,
    format('request=%s total=%s', v_request, v_total)
  );

  -- Every mutation below is contained in a deliberate subtransaction rollback.
  v_fixture := direct_delivery_test.create_request('payment_review');
  v_request := (v_fixture->>'request_id')::uuid;
  v_total := (v_fixture->>'final_total')::numeric;
  BEGIN
    v_ok := direct_delivery_test.expect_approval_error(
      v_request, v_total + 1, 'DIRECT_ORDER_PAYMENT_AMOUNT_MISMATCH'
    );
    RAISE EXCEPTION 'DIRECT_TEST_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'DIRECT_TEST_ROLLBACK' THEN RAISE; END IF;
  END;
  INSERT INTO _direct_precondition_results VALUES (
    'one VND mismatch is rejected', v_ok, 'exact numeric equality is required'
  );

  v_fixture := direct_delivery_test.create_request('payment_review');
  v_request := (v_fixture->>'request_id')::uuid;
  v_total := (v_fixture->>'final_total')::numeric;
  BEGIN
    UPDATE public.direct_order_quotes
    SET created_at = now() - interval '2 minutes',
        expires_at = now() - interval '1 minute'
    WHERE request_id = v_request AND status = 'locked';
    v_ok := direct_delivery_test.expect_approval_error(
      v_request, v_total, 'DIRECT_ORDER_QUOTE_EXPIRED'
    );
    RAISE EXCEPTION 'DIRECT_TEST_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'DIRECT_TEST_ROLLBACK' THEN RAISE; END IF;
  END;
  INSERT INTO _direct_precondition_results VALUES (
    'expired locked quote is rejected', v_ok, 'expiry is checked at approval'
  );

  v_fixture := direct_delivery_test.create_request('payment_review');
  v_request := (v_fixture->>'request_id')::uuid;
  v_total := (v_fixture->>'final_total')::numeric;
  BEGIN
    DELETE FROM public.direct_order_messages
    WHERE request_id = v_request AND message_type = 'payment_proof';
    v_ok := direct_delivery_test.expect_approval_error(
      v_request, v_total, 'DIRECT_ORDER_PAYMENT_PROOF_REQUIRED'
    );
    RAISE EXCEPTION 'DIRECT_TEST_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'DIRECT_TEST_ROLLBACK' THEN RAISE; END IF;
  END;
  INSERT INTO _direct_precondition_results VALUES (
    'missing proof is rejected', v_ok, 'manual evidence remains mandatory'
  );

  v_fixture := direct_delivery_test.create_request('quoted');
  v_request := (v_fixture->>'request_id')::uuid;
  v_session := (v_fixture->>'session_id')::uuid;
  v_secret := v_fixture->>'secret_hash';
  v_error := NULL;
  BEGIN
    PERFORM public.direct_order_public_commit_proof(
      v_session, v_secret, v_request,
      v_store::text || '/' || v_request::text || '/not-a-uuid.jpg'
    );
  EXCEPTION WHEN OTHERS THEN
    v_error := SQLERRM;
  END;
  INSERT INTO _direct_precondition_results VALUES (
    'forged proof path is rejected',
    v_error = 'DIRECT_ORDER_PROOF_PATH_INVALID'
      AND EXISTS (
        SELECT 1 FROM public.direct_order_requests request_row
        WHERE request_row.id = v_request AND request_row.state = 'quoted'
      )
      AND NOT EXISTS (
        SELECT 1 FROM public.direct_order_messages message
        WHERE message.request_id = v_request
          AND message.message_type = 'payment_proof'
      ),
    format('error=%s', v_error)
  );
  PERFORM direct_delivery_test.cancel(v_request);

  v_fixture := direct_delivery_test.create_request('payment_review');
  v_request := (v_fixture->>'request_id')::uuid;
  v_total := (v_fixture->>'final_total')::numeric;
  BEGIN
    UPDATE public.menu_items SET is_available = false WHERE id = v_menu;
    v_ok := direct_delivery_test.expect_approval_error(
      v_request, v_total, 'DIRECT_ORDER_MENU_CHANGED'
    );
    RAISE EXCEPTION 'DIRECT_TEST_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'DIRECT_TEST_ROLLBACK' THEN RAISE; END IF;
  END;
  INSERT INTO _direct_precondition_results VALUES (
    'menu availability change is rejected', v_ok, 'snapshot is immutable'
  );

  BEGIN
    UPDATE public.menu_items SET is_visible_public = false WHERE id = v_menu;
    v_ok := direct_delivery_test.expect_approval_error(
      v_request, v_total, 'DIRECT_ORDER_MENU_CHANGED'
    );
    RAISE EXCEPTION 'DIRECT_TEST_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'DIRECT_TEST_ROLLBACK' THEN RAISE; END IF;
  END;
  INSERT INTO _direct_precondition_results VALUES (
    'menu visibility change is rejected', v_ok, 'hidden item cannot approve'
  );

  BEGIN
    UPDATE public.menu_items SET price = price + 1 WHERE id = v_menu;
    v_ok := direct_delivery_test.expect_approval_error(
      v_request, v_total, 'DIRECT_ORDER_MENU_CHANGED'
    );
    RAISE EXCEPTION 'DIRECT_TEST_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'DIRECT_TEST_ROLLBACK' THEN RAISE; END IF;
  END;
  INSERT INTO _direct_precondition_results VALUES (
    'menu price change is rejected', v_ok, 'quoted unit price must still match'
  );

  BEGIN
    UPDATE public.direct_order_storefronts
    SET is_enabled = false WHERE restaurant_id = v_store;
    v_ok := direct_delivery_test.expect_approval_error(
      v_request, v_total, 'DIRECT_ORDER_STOREFRONT_DISABLED'
    );
    RAISE EXCEPTION 'DIRECT_TEST_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'DIRECT_TEST_ROLLBACK' THEN RAISE; END IF;
  END;
  INSERT INTO _direct_precondition_results VALUES (
    'disabled storefront is rejected', v_ok, 'approval fails closed'
  );

  BEGIN
    UPDATE public.direct_order_storefronts
    SET is_paused = true WHERE restaurant_id = v_store;
    v_ok := direct_delivery_test.expect_approval_error(
      v_request, v_total, 'DIRECT_ORDER_STOREFRONT_DISABLED'
    );
    RAISE EXCEPTION 'DIRECT_TEST_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'DIRECT_TEST_ROLLBACK' THEN RAISE; END IF;
  END;
  INSERT INTO _direct_precondition_results VALUES (
    'paused storefront is rejected', v_ok, 'pause blocks manual approval'
  );

  v_ok := false;
  BEGIN
    UPDATE public.direct_order_storefronts
    SET accounting_approved_at = NULL, accounting_approved_by = NULL
    WHERE restaurant_id = v_store;
  EXCEPTION WHEN check_violation THEN
    v_ok := true;
  END;
  INSERT INTO _direct_precondition_results VALUES (
    'enabled storefront requires accounting approval',
    v_ok AND EXISTS (
      SELECT 1 FROM public.direct_order_storefronts storefront
      WHERE storefront.restaurant_id = v_store
        AND storefront.accounting_approved_at IS NOT NULL
        AND storefront.accounting_approved_by IS NOT NULL
    ),
    'database constraint is fail-closed'
  );

  BEGIN
    PERFORM set_config('direct_order.test_local_time', '21:30', true);
    v_ok := direct_delivery_test.expect_approval_error(
      v_request, v_total, 'DIRECT_ORDER_APPROVAL_CUTOFF'
    );
    RAISE EXCEPTION 'DIRECT_TEST_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'DIRECT_TEST_ROLLBACK' THEN RAISE; END IF;
  END;
  INSERT INTO _direct_precondition_results VALUES (
    'binding 21:30 cutoff is rejected', v_ok, 'test-only clock at exact boundary'
  );

  BEGIN
    UPDATE public.restaurant_settings
    SET fulfillment_mode = 'paperless'
    WHERE restaurant_id = v_store;
    v_ok := direct_delivery_test.expect_approval_error(
      v_request, v_total, 'DIRECT_ORDER_REQUIRES_POS_PRINT'
    );
    RAISE EXCEPTION 'DIRECT_TEST_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'DIRECT_TEST_ROLLBACK' THEN RAISE; END IF;
  END;
  INSERT INTO _direct_precondition_results VALUES (
    'non-pos_print fulfillment is rejected', v_ok, 'legacy print mode gate'
  );

  BEGIN
    INSERT INTO public.emergency_fulfillment_sessions(
      restaurant_id, status, reason, activated_by
    ) VALUES (v_store, 'active', 'direct guard test', v_user);
    v_ok := direct_delivery_test.expect_approval_error(
      v_request, v_total, 'DIRECT_ORDER_EMERGENCY_ACTIVE'
    );
    RAISE EXCEPTION 'DIRECT_TEST_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'DIRECT_TEST_ROLLBACK' THEN RAISE; END IF;
  END;
  INSERT INTO _direct_precondition_results VALUES (
    'active emergency session is rejected', v_ok, 'emergency mode wins'
  );

  BEGIN
    INSERT INTO public.store_promotions(
      restaurant_id, name, discount_percent, starts_at, ends_at,
      channel, is_active, created_by, scope
    ) VALUES (
      v_store, 'Direct guard promotion', 5,
      now() - interval '1 hour', now() + interval '1 hour',
      'both', true, v_auth, 'all_menu'
    );
    v_ok := direct_delivery_test.expect_approval_error(
      v_request, v_total, 'DIRECT_ORDER_PROMOTION_ACTIVE'
    );
    RAISE EXCEPTION 'DIRECT_TEST_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'DIRECT_TEST_ROLLBACK' THEN RAISE; END IF;
  END;
  INSERT INTO _direct_precondition_results VALUES (
    'active promotion is rejected', v_ok, 'promotion reconciliation is isolated'
  );

  PERFORM direct_delivery_test.set_actor();
  v_error := NULL;
  BEGIN
    PERFORM public.direct_order_approve_payment(
      gen_random_uuid(), v_request, v_total, 'wrong-store'
    );
  EXCEPTION WHEN OTHERS THEN
    v_error := SQLERRM;
  END;
  INSERT INTO _direct_precondition_results VALUES (
    'wrong store is rejected',
    v_error = 'DIRECT_ORDER_FORBIDDEN'
      AND direct_delivery_test.graph_is_empty(v_request),
    format('error=%s', v_error)
  );

  PERFORM set_config('request.jwt.claim.sub', v_kitchen_auth::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
  v_error := NULL;
  BEGIN
    PERFORM public.direct_order_approve_payment(
      v_store, v_request, v_total, 'wrong-role'
    );
  EXCEPTION WHEN OTHERS THEN
    v_error := SQLERRM;
  END;
  INSERT INTO _direct_precondition_results VALUES (
    'wrong role is rejected',
    v_error = 'DIRECT_ORDER_FORBIDDEN'
      AND direct_delivery_test.graph_is_empty(v_request),
    format('error=%s', v_error)
  );
END;
$contract$;

DO $assertions$
DECLARE v_failures text;
BEGIN
  SELECT string_agg(scenario || ': ' || COALESCE(detail, ''), E'\n')
  INTO v_failures
  FROM _direct_precondition_results
  WHERE NOT ok;
  IF v_failures IS NOT NULL THEN
    RAISE EXCEPTION E'DIRECT_DELIVERY_PRECONDITION_CONTRACT_FAILED:\n%',
      v_failures;
  END IF;
END;
$assertions$;

SELECT scenario, detail
FROM _direct_precondition_results
ORDER BY scenario;

ROLLBACK;
