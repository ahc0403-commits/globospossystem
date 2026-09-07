-- Cashier-controlled direct-delivery availability contract.
-- Run only against the disposable codex_direct_* database used by the suite.
\set ON_ERROR_STOP on

BEGIN;

\ir fixtures/direct_delivery_test_fixture.sql

DO $contract$
DECLARE
  v_store uuid;
  v_auth uuid;
  v_user uuid;
  v_menu uuid;
  v_missing_store uuid := 'de300000-0000-4000-8000-000000000001';
  v_session uuid;
  v_secret text;
  v_request uuid;
  v_total numeric;
  v_payload jsonb;
  v_result jsonb;
  v_before jsonb;
  v_after jsonb;
  v_updated_at timestamptz;
  v_audit_count bigint;
  v_error text;
BEGIN
  SELECT store_id, auth_id, user_id, menu_item_id
  INTO v_store, v_auth, v_user, v_menu
  FROM direct_delivery_test.constants
  LIMIT 1;

  PERFORM direct_delivery_test.set_actor();
  v_result := public.direct_order_staff_get_availability(v_store);
  IF v_result <> jsonb_build_object(
       'configured', true,
       'enabled', true,
       'paused', false,
       'updated_at', (v_result->'updated_at')
     ) THEN
    RAISE EXCEPTION 'AVAILABILITY_READ_CONTRACT_FAILED:%', v_result;
  END IF;

  SELECT to_jsonb(storefront) - ARRAY['is_paused', 'updated_at', 'updated_by']
  INTO v_before
  FROM public.direct_order_storefronts storefront
  WHERE storefront.restaurant_id = v_store;

  v_result := public.direct_order_staff_set_paused(v_store, true);
  IF (v_result->>'paused')::boolean IS DISTINCT FROM true
     OR (v_result->>'configured')::boolean IS DISTINCT FROM true
     OR (v_result->>'enabled')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'AVAILABILITY_CLOSE_RESULT_FAILED:%', v_result;
  END IF;

  SELECT to_jsonb(storefront) - ARRAY['is_paused', 'updated_at', 'updated_by'],
         storefront.updated_at
  INTO v_after, v_updated_at
  FROM public.direct_order_storefronts storefront
  WHERE storefront.restaurant_id = v_store;
  IF v_after IS DISTINCT FROM v_before THEN
    RAISE EXCEPTION 'AVAILABILITY_MUTATED_UNRELATED_FIELDS';
  END IF;

  SELECT count(*) INTO v_audit_count
  FROM public.audit_logs audit
  WHERE audit.action = 'direct_order_intake_availability_changed'
    AND audit.entity_id = v_store;
  IF v_audit_count <> 1 OR NOT EXISTS (
    SELECT 1
    FROM public.audit_logs audit
    WHERE audit.action = 'direct_order_intake_availability_changed'
      AND audit.entity_id = v_store
      AND audit.actor_id = v_auth
      AND audit.details @> jsonb_build_object(
        'store_id', v_store,
        'previous_paused', false,
        'paused', true,
        'source', 'cashier_main'
      )
  ) THEN
    RAISE EXCEPTION 'AVAILABILITY_AUDIT_FAILED:%', v_audit_count;
  END IF;

  -- Set-to-value replay is idempotent: no timestamp or audit churn.
  v_result := public.direct_order_staff_set_paused(v_store, true);
  IF (v_result->>'paused')::boolean IS DISTINCT FROM true
     OR (SELECT storefront.updated_at
         FROM public.direct_order_storefronts storefront
         WHERE storefront.restaurant_id = v_store) IS DISTINCT FROM v_updated_at
     OR (SELECT count(*)
         FROM public.audit_logs audit
         WHERE audit.action = 'direct_order_intake_availability_changed'
           AND audit.entity_id = v_store) <> v_audit_count THEN
    RAISE EXCEPTION 'AVAILABILITY_IDEMPOTENCY_FAILED:%', v_result;
  END IF;

  -- CLOSED blocks a new public submission at the authoritative server guard.
  v_session := gen_random_uuid();
  v_secret := replace(gen_random_uuid()::text, '-', '') ||
    replace(gen_random_uuid()::text, '-', '');
  INSERT INTO public.direct_order_sessions(
    id, restaurant_id, secret_hash, locale
  ) VALUES (v_session, v_store, v_secret, 'vi');
  v_payload := jsonb_build_object(
    'locale', 'vi',
    'items', jsonb_build_array(jsonb_build_object(
      'menu_item_id', v_menu,
      'quantity', 1
    )),
    'address', jsonb_build_object(
      'customer_name', 'Paused Customer',
      'customer_phone', '+84901234567',
      'formatted_address', '123 Nguyen Hue, District 1, HCMC',
      'detail_address', 'Floor 4',
      'latitude', 10.775,
      'longitude', 106.704,
      'address_source', 'search',
      'location_verified', true
    )
  );
  v_error := NULL;
  BEGIN
    PERFORM public.direct_order_public_submit(
      v_session, v_secret, gen_random_uuid(), v_payload
    );
  EXCEPTION WHEN OTHERS THEN
    v_error := SQLERRM;
  END;
  IF v_error <> 'DIRECT_ORDER_STOREFRONT_PAUSED'
     OR EXISTS (
       SELECT 1 FROM public.direct_order_requests request_row
       WHERE request_row.session_id = v_session
     ) THEN
    RAISE EXCEPTION 'AVAILABILITY_NEW_INTAKE_GUARD_FAILED:%', v_error;
  END IF;

  -- Requests created before CLOSED can still receive a quote.
  PERFORM public.direct_order_staff_set_paused(v_store, false);
  v_result := direct_delivery_test.create_request('awaiting_quote');
  v_request := (v_result->>'request_id')::uuid;
  PERFORM public.direct_order_staff_set_paused(v_store, true);
  PERFORM public.direct_order_staff_quote(
    v_store, v_request, 25000, 'quote while new intake is closed'
  );
  IF NOT EXISTS (
    SELECT 1 FROM public.direct_order_requests request_row
    WHERE request_row.id = v_request AND request_row.state = 'quoted'
  ) THEN
    RAISE EXCEPTION 'AVAILABILITY_EXISTING_QUOTE_BLOCKED';
  END IF;
  PERFORM direct_delivery_test.cancel(v_request);

  -- Requests that already reached payment review can still be approved.
  PERFORM public.direct_order_staff_set_paused(v_store, false);
  v_result := direct_delivery_test.create_request('payment_review');
  v_request := (v_result->>'request_id')::uuid;
  v_total := (v_result->>'final_total')::numeric;
  PERFORM public.direct_order_staff_set_paused(v_store, true);
  v_result := direct_delivery_test.approve(v_request, v_total);
  PERFORM direct_delivery_test.assert_single_graph(v_request);
  IF COALESCE((v_result->>'idempotent')::boolean, true) THEN
    RAISE EXCEPTION 'AVAILABILITY_EXISTING_APPROVAL_FAILED:%', v_result;
  END IF;

  -- A disabled storefront is readable as disabled but cannot be opened here.
  UPDATE public.direct_order_storefronts
  SET is_enabled = false
  WHERE restaurant_id = v_store;
  v_result := public.direct_order_staff_get_availability(v_store);
  IF (v_result->>'configured')::boolean IS DISTINCT FROM true
     OR (v_result->>'enabled')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'AVAILABILITY_DISABLED_READ_FAILED:%', v_result;
  END IF;
  v_error := NULL;
  BEGIN
    PERFORM public.direct_order_staff_set_paused(v_store, false);
  EXCEPTION WHEN OTHERS THEN
    v_error := SQLERRM;
  END;
  IF v_error <> 'DIRECT_ORDER_STOREFRONT_DISABLED' THEN
    RAISE EXCEPTION 'AVAILABILITY_DISABLED_SET_FAILED:%', v_error;
  END IF;
  UPDATE public.direct_order_storefronts
  SET is_enabled = true
  WHERE restaurant_id = v_store;

  -- An accessible but unconfigured store returns a minimal safe state.
  INSERT INTO public.restaurants(
    id, name, address, slug, operation_mode, is_active,
    brand_id, tax_entity_id, vat_pricing_mode
  )
  SELECT v_missing_store, 'Unconfigured Direct Store', 'Disposable address',
         'unconfigured-direct-store', 'standard', true,
         source.brand_id, source.tax_entity_id, 'exclusive'
  FROM public.restaurants source
  WHERE source.id = v_store;
  INSERT INTO public.user_store_access(
    user_id, store_id, is_primary, is_active, source_type
  ) VALUES (v_user, v_missing_store, false, true, 'direct');
  v_result := public.direct_order_staff_get_availability(v_missing_store);
  IF v_result <> jsonb_build_object(
       'configured', false,
       'enabled', false,
       'paused', false,
       'updated_at', NULL
     ) THEN
    RAISE EXCEPTION 'AVAILABILITY_UNCONFIGURED_READ_FAILED:%', v_result;
  END IF;
  v_error := NULL;
  BEGIN
    PERFORM public.direct_order_staff_set_paused(v_missing_store, true);
  EXCEPTION WHEN OTHERS THEN
    v_error := SQLERRM;
  END;
  IF v_error <> 'DIRECT_ORDER_STOREFRONT_DISABLED' THEN
    RAISE EXCEPTION 'AVAILABILITY_UNCONFIGURED_SET_FAILED:%', v_error;
  END IF;

  -- Admin is allowed; kitchen and waiter are not.
  UPDATE public.users SET role = 'admin' WHERE id = v_user;
  PERFORM public.direct_order_staff_get_availability(v_store);
  PERFORM public.direct_order_staff_set_paused(v_store, false);

  FOREACH v_error IN ARRAY ARRAY['kitchen', 'waiter'] LOOP
    UPDATE public.users SET role = v_error WHERE id = v_user;
    PERFORM direct_delivery_test.set_actor();
    BEGIN
      PERFORM public.direct_order_staff_get_availability(v_store);
      RAISE EXCEPTION 'AVAILABILITY_FORBIDDEN_READ_NOT_BLOCKED:%', v_error;
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM <> 'DIRECT_ORDER_FORBIDDEN' THEN RAISE; END IF;
    END;
    BEGIN
      PERFORM public.direct_order_staff_set_paused(v_store, true);
      RAISE EXCEPTION 'AVAILABILITY_FORBIDDEN_SET_NOT_BLOCKED:%', v_error;
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM <> 'DIRECT_ORDER_FORBIDDEN' THEN RAISE; END IF;
    END;
  END LOOP;

  -- Same-role users cannot cross the store-access boundary.
  UPDATE public.users SET role = 'cashier' WHERE id = v_user;
  PERFORM direct_delivery_test.set_actor();
  v_error := NULL;
  BEGIN
    PERFORM public.direct_order_staff_get_availability(gen_random_uuid());
  EXCEPTION WHEN OTHERS THEN
    v_error := SQLERRM;
  END;
  IF v_error <> 'DIRECT_ORDER_FORBIDDEN' THEN
    RAISE EXCEPTION 'AVAILABILITY_CROSS_STORE_READ_FAILED:%', v_error;
  END IF;
  v_error := NULL;
  BEGIN
    PERFORM public.direct_order_staff_set_paused(gen_random_uuid(), true);
  EXCEPTION WHEN OTHERS THEN
    v_error := SQLERRM;
  END;
  IF v_error <> 'DIRECT_ORDER_FORBIDDEN' THEN
    RAISE EXCEPTION 'AVAILABILITY_CROSS_STORE_SET_FAILED:%', v_error;
  END IF;
END;
$contract$;

SELECT 'DIRECT_DELIVERY_AVAILABILITY_CONTRACT_PASS' AS result;

ROLLBACK;
