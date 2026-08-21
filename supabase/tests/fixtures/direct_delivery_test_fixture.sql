-- Test-only fixture. Never apply to production or a non-codex database.
\set ON_ERROR_STOP on

DO $guard$
BEGIN
  IF current_database() !~ '^codex_direct_' THEN
    RAISE EXCEPTION 'DIRECT_DELIVERY_TEST_REQUIRES_CODEX_DISPOSABLE_DB:%',
      current_database();
  END IF;
END;
$guard$;

DROP SCHEMA IF EXISTS direct_delivery_test CASCADE;
CREATE SCHEMA direct_delivery_test;

-- Approval has a binding 21:30 HCM cutoff. State/concurrency/rollback tests
-- must be deterministic at any wall-clock time, so only a guarded disposable
-- database receives this test-only clock substitution. The migration source
-- and production function remain unchanged.
\ir direct_delivery_test_clock.sql

CREATE TABLE direct_delivery_test.constants (
  store_id uuid PRIMARY KEY,
  auth_id uuid NOT NULL,
  user_id uuid NOT NULL,
  menu_item_id uuid NOT NULL,
  ingredient_id uuid NOT NULL
);

DO $fixture$
DECLARE
  v_store uuid := 'de100000-0000-4000-8000-000000000001';
  v_auth uuid := 'de100000-0000-4000-8000-000000000002';
  v_user uuid := 'de100000-0000-4000-8000-000000000003';
  v_menu uuid := 'de100000-0000-4000-8000-000000000004';
  v_ingredient uuid := 'de100000-0000-4000-8000-000000000005';
BEGIN
  INSERT INTO public.restaurants(
    id, name, address, slug, operation_mode, is_active,
    brand_id, tax_entity_id, vat_pricing_mode
  )
  SELECT
    v_store, 'Direct Delivery Test Store', 'Disposable test address',
    'direct-delivery-test-store', 'standard', true,
    source_store.brand_id, source_store.tax_entity_id, 'exclusive'
  FROM public.restaurants source_store
  WHERE source_store.brand_id IS NOT NULL
    AND source_store.tax_entity_id IS NOT NULL
  ORDER BY source_store.created_at, source_store.id
  LIMIT 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'DIRECT_DELIVERY_TEST_NEEDS_SEEDED_STORE';
  END IF;

  INSERT INTO auth.users(id, email)
  VALUES (v_auth, 'direct.delivery.test@globos.test')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.users(
    id, auth_id, restaurant_id, role, full_name, is_active
  ) VALUES (
    v_user, v_auth, v_store, 'cashier', 'Direct Delivery Test Cashier', true
  );

  INSERT INTO public.user_store_access(
    user_id, store_id, is_primary, is_active, source_type
  ) VALUES (v_user, v_store, true, true, 'direct');

  INSERT INTO public.restaurant_settings(
    restaurant_id, settings_json, fulfillment_mode
  ) VALUES (v_store, '{}'::jsonb, 'pos_print')
  ON CONFLICT (restaurant_id) DO UPDATE
  SET fulfillment_mode='pos_print';

  INSERT INTO public.direct_order_storefronts(
    restaurant_id, public_slug, is_enabled, is_paused,
    ordering_starts_at, ordering_cutoff_at,
    bank_bin, bank_account_number, bank_account_holder,
    delivery_fee_vat_rate, accounting_approved_at, accounting_approved_by
  ) VALUES (
    v_store, 'direct-delivery-test', true, false, '00:00', '21:30',
    '970436', '123456789', 'GLOBOS TEST', 0, now(), v_auth
  );

  INSERT INTO public.menu_items(
    id, restaurant_id, name, name_ko, name_vi, name_en,
    price, vat_category, is_available, is_visible_public
  ) VALUES (
    v_menu, v_store, 'Direct Test Menu',
    '직접 테스트 메뉴', 'Món thử giao hàng', 'Direct test menu',
    100000, 'food', true, true
  );

  INSERT INTO public.inventory_items(
    id, restaurant_id, name, quantity, unit, current_stock
  ) VALUES (
    v_ingredient, v_store, 'Direct Test Ingredient', 10000, 'g', 10000
  );

  INSERT INTO public.menu_recipes(
    restaurant_id, menu_item_id, ingredient_id, quantity_g
  ) VALUES (v_store, v_menu, v_ingredient, 10);

  INSERT INTO direct_delivery_test.constants
  VALUES (v_store, v_auth, v_user, v_menu, v_ingredient);
END;
$fixture$;

CREATE OR REPLACE FUNCTION direct_delivery_test.set_actor()
RETURNS void
LANGUAGE plpgsql
AS $function$
DECLARE v_auth uuid;
BEGIN
  SELECT auth_id INTO v_auth FROM direct_delivery_test.constants LIMIT 1;
  PERFORM set_config('request.jwt.claim.sub', v_auth::text, true);
  PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
END;
$function$;

CREATE OR REPLACE FUNCTION direct_delivery_test.create_request(
  p_stage text DEFAULT 'payment_review'
) RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
  v_constant direct_delivery_test.constants%ROWTYPE;
  v_session uuid := gen_random_uuid();
  v_secret_hash text := replace(gen_random_uuid()::text, '-', '') ||
    replace(gen_random_uuid()::text, '-', '');
  v_submit jsonb;
  v_quote jsonb;
  v_request uuid;
BEGIN
  IF p_stage NOT IN ('awaiting_quote', 'quoted', 'payment_review') THEN
    RAISE EXCEPTION 'DIRECT_DELIVERY_TEST_STAGE_INVALID';
  END IF;
  SELECT * INTO v_constant FROM direct_delivery_test.constants LIMIT 1;
  INSERT INTO public.direct_order_sessions(
    id, restaurant_id, secret_hash, locale
  ) VALUES (v_session, v_constant.store_id, v_secret_hash, 'vi');

  v_submit := public.direct_order_public_submit(
    v_session,
    v_secret_hash,
    gen_random_uuid(),
    jsonb_build_object(
      'locale', 'vi',
      'items', jsonb_build_array(jsonb_build_object(
        'menu_item_id', v_constant.menu_item_id,
        'quantity', 1,
        'note', 'test item note'
      )),
      'address', jsonb_build_object(
        'customer_name', 'Test Customer',
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
    )
  );
  v_request := (v_submit->>'request_id')::uuid;

  IF p_stage IN ('quoted', 'payment_review') THEN
    PERFORM direct_delivery_test.set_actor();
    v_quote := public.direct_order_staff_quote(
      v_constant.store_id, v_request, 25000, 'test quote'
    );
  END IF;
  IF p_stage = 'payment_review' THEN
    PERFORM public.direct_order_public_commit_proof(
      v_session,
      v_secret_hash,
      v_request,
      v_constant.store_id::text || '/' || v_request::text || '/' ||
        gen_random_uuid()::text || '.jpg'
    );
  END IF;

  RETURN jsonb_build_object(
    'store_id', v_constant.store_id,
    'auth_id', v_constant.auth_id,
    'session_id', v_session,
    'secret_hash', v_secret_hash,
    'request_id', v_request,
    'reference_code', v_submit->>'reference_code',
    'quote_id', v_quote->>'id',
    'final_total', v_quote->>'final_total'
  );
END;
$function$;

CREATE OR REPLACE FUNCTION direct_delivery_test.approve(
  p_request_id uuid,
  p_amount numeric
) RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE v_store uuid;
BEGIN
  SELECT store_id INTO v_store FROM direct_delivery_test.constants LIMIT 1;
  PERFORM direct_delivery_test.set_actor();
  RETURN public.direct_order_approve_payment(
    v_store, p_request_id, p_amount, 'test-bank-reference'
  );
END;
$function$;

CREATE OR REPLACE FUNCTION direct_delivery_test.reject(
  p_request_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE v_store uuid;
BEGIN
  SELECT store_id INTO v_store FROM direct_delivery_test.constants LIMIT 1;
  PERFORM direct_delivery_test.set_actor();
  RETURN public.direct_order_staff_reject(
    v_store, p_request_id, 'test rejection reason'
  );
END;
$function$;

CREATE OR REPLACE FUNCTION direct_delivery_test.cancel(
  p_request_id uuid
) RETURNS jsonb
LANGUAGE plpgsql
AS $function$
DECLARE
  v_session uuid;
  v_secret_hash text;
BEGIN
  SELECT request_row.session_id, session_row.secret_hash
  INTO v_session, v_secret_hash
  FROM public.direct_order_requests request_row
  JOIN public.direct_order_sessions session_row ON session_row.id=request_row.session_id
  WHERE request_row.id=p_request_id;
  RETURN public.direct_order_public_cancel(
    v_session, v_secret_hash, p_request_id
  );
END;
$function$;

CREATE OR REPLACE FUNCTION direct_delivery_test.assert_single_graph(
  p_request_id uuid
) RETURNS void
LANGUAGE plpgsql
AS $function$
DECLARE
  v_financial public.direct_order_financials%ROWTYPE;
BEGIN
  SELECT * INTO v_financial
  FROM public.direct_order_financials
  WHERE request_id=p_request_id;
  IF NOT FOUND
     OR (SELECT count(*) FROM public.direct_order_financials
         WHERE request_id=p_request_id) <> 1
     OR (SELECT count(*) FROM public.orders WHERE id=v_financial.order_id) <> 1
     OR (SELECT count(*) FROM public.payments WHERE id=v_financial.payment_id) <> 1
     OR (SELECT count(*) FROM public.direct_delivery_fulfillment_tickets
         WHERE request_id=p_request_id) <> 1 THEN
    RAISE EXCEPTION 'DIRECT_DELIVERY_TEST_GRAPH_NOT_SINGLE:%', p_request_id;
  END IF;
END;
$function$;
