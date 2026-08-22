-- Viewer/request locale and immutable KO/VI/EN snapshot contract.
-- Disposable DB only.
\set ON_ERROR_STOP on
BEGIN;
\ir fixtures/direct_delivery_test_fixture.sql

CREATE TEMP TABLE _direct_locale_results (
  scenario text PRIMARY KEY,
  ok boolean NOT NULL,
  detail text
);

DO $contract$
DECLARE
  v_store uuid;
  v_menu uuid;
  v_locale text;
  v_secret_hash text;
  v_session jsonb;
  v_session_id uuid;
  v_request jsonb;
  v_request_id uuid;
  v_invalid_client uuid := gen_random_uuid();
  v_invalid_blocked boolean := false;
  v_create_invalid_blocked boolean := false;
  v_fixture jsonb;
  v_approval jsonb;
  v_ticket_id uuid;
  v_ticket_list jsonb;
BEGIN
  SELECT store_id, menu_item_id INTO v_store, v_menu
  FROM direct_delivery_test.constants LIMIT 1;

  FOREACH v_locale IN ARRAY ARRAY['ko', 'vi', 'en'] LOOP
    v_secret_hash := replace(gen_random_uuid()::text, '-', '') ||
      replace(gen_random_uuid()::text, '-', '');
    v_session := public.direct_order_public_create_session(
      'direct-delivery-test', v_secret_hash, v_locale
    );
    v_session_id := (v_session->>'session_id')::uuid;
    v_request := public.direct_order_public_submit(
      v_session_id,
      v_secret_hash,
      gen_random_uuid(),
      jsonb_build_object(
        'locale', v_locale,
        'items', jsonb_build_array(jsonb_build_object(
          'menu_item_id', v_menu,
          'quantity', 1,
          'note', 'Không dịch / 번역하지 않음 / do not translate'
        )),
        'customer_note', 'Giữ nguyên / 원문 / original',
        'address', jsonb_build_object(
          'customer_name', 'Locale Customer',
          'customer_phone', '+84901234567',
          'formatted_address', '123 Nguyễn Huệ, Quận 1, TP.HCM',
          'detail_address', 'Tầng 4 / 4층',
          'latitude', 10.775,
          'longitude', 106.704,
          'google_place_id', 'locale-place-id',
          'district', 'Quận 1',
          'ward', 'Bến Nghé',
          'address_source', 'search',
          'location_verified', true
        )
      )
    );
    v_request_id := (v_request->>'request_id')::uuid;
    INSERT INTO _direct_locale_results VALUES (
      'session and request accept ' || v_locale,
      EXISTS (
        SELECT 1 FROM public.direct_order_sessions session_row
        WHERE session_row.id=v_session_id AND session_row.locale=v_locale
      ) AND EXISTS (
        SELECT 1 FROM public.direct_order_requests request_row
        WHERE request_row.id=v_request_id AND request_row.locale=v_locale
          AND request_row.customer_note='Giữ nguyên / 원문 / original'
      ) AND EXISTS (
        SELECT 1 FROM public.direct_order_request_addresses address
        WHERE address.request_id=v_request_id
          AND address.formatted_address='123 Nguyễn Huệ, Quận 1, TP.HCM'
          AND address.detail_address='Tầng 4 / 4층'
      ),
      'request locale is metadata; exact free text is preserved'
    );
  END LOOP;

  BEGIN
    PERFORM public.direct_order_public_create_session(
      'direct-delivery-test',
      replace(gen_random_uuid()::text, '-', '') ||
        replace(gen_random_uuid()::text, '-', ''),
      'fr'
    );
  EXCEPTION WHEN OTHERS THEN
    v_create_invalid_blocked := SQLERRM LIKE '%DIRECT_ORDER_SESSION_INPUT_INVALID%';
  END;
  INSERT INTO _direct_locale_results VALUES (
    'session rejects unsupported locale',
    v_create_invalid_blocked,
    'only ko vi en are accepted'
  );

  v_secret_hash := replace(gen_random_uuid()::text, '-', '') ||
    replace(gen_random_uuid()::text, '-', '');
  v_session := public.direct_order_public_create_session(
    'direct-delivery-test', v_secret_hash, 'vi'
  );
  v_session_id := (v_session->>'session_id')::uuid;
  BEGIN
    PERFORM public.direct_order_public_submit(
      v_session_id,
      v_secret_hash,
      v_invalid_client,
      jsonb_build_object(
        'locale', 'fr',
        'items', jsonb_build_array(jsonb_build_object(
          'menu_item_id', v_menu, 'quantity', 1
        )),
        'address', jsonb_build_object(
          'customer_name', 'Invalid Locale',
          'customer_phone', '+84901234567',
          'formatted_address', '123 Test',
          'detail_address', 'Floor 4',
          'latitude', 10.775,
          'longitude', 106.704,
          'address_source', 'map_pin',
          'location_verified', true
        )
      )
    );
  EXCEPTION WHEN OTHERS THEN
    v_invalid_blocked := SQLERRM LIKE '%DIRECT_ORDER_REQUEST_INPUT_INVALID%';
  END;
  INSERT INTO _direct_locale_results VALUES (
    'submit rejects unsupported locale before writes',
    v_invalid_blocked AND NOT EXISTS (
      SELECT 1 FROM public.direct_order_requests
      WHERE client_request_id=v_invalid_client
    ),
    'invalid request locale cannot reach persisted state'
  );

  v_fixture := direct_delivery_test.create_request('payment_review');
  v_approval := direct_delivery_test.approve(
    (v_fixture->>'request_id')::uuid,
    (v_fixture->>'final_total')::numeric
  );
  v_ticket_id := (v_approval->>'ticket_id')::uuid;
  PERFORM direct_delivery_test.set_actor();
  v_ticket_list := public.direct_delivery_ticket_list(
    v_store, NULL, NULL, NULL, 200
  );
  INSERT INTO _direct_locale_results VALUES (
    'approval copies all three immutable ticket item names',
    EXISTS (
      SELECT 1 FROM public.direct_delivery_fulfillment_ticket_items item
      WHERE item.ticket_id=v_ticket_id
        AND item.display_name_ko='직접 테스트 메뉴'
        AND item.display_name_vi='Món thử giao hàng'
        AND item.display_name_en='Direct test menu'
    ) AND EXISTS (
      SELECT 1
      FROM jsonb_array_elements(v_ticket_list) ticket,
           jsonb_array_elements(ticket->'items') item
      WHERE ticket->>'id'=v_ticket_id::text
        AND item->>'name_ko'='직접 테스트 메뉴'
        AND item->>'name_vi'='Món thử giao hàng'
        AND item->>'name_en'='Direct test menu'
    ),
    'ticket API reads approval snapshots, never live menu names'
  );
END;
$contract$;

DO $assert$
DECLARE v_failures text;
BEGIN
  SELECT string_agg(scenario || ': ' || detail, E'\n' ORDER BY scenario)
  INTO v_failures
  FROM _direct_locale_results WHERE NOT ok;
  IF v_failures IS NOT NULL THEN
    RAISE EXCEPTION E'DIRECT_DELIVERY_LOCALE_CONTRACT_FAILED:\n%', v_failures;
  END IF;
END;
$assert$;

SELECT 'DIRECT_DELIVERY_LOCALE_CONTRACT_PASS' AS result,
       count(*) AS scenarios
FROM _direct_locale_results;

ROLLBACK;
