-- Payload-free direct arrival event, cursor, replay, and role contract.
-- Disposable DB only; requires both direct-delivery migrations.
\set ON_ERROR_STOP on
BEGIN;
\ir fixtures/direct_delivery_test_fixture.sql

CREATE TEMP TABLE _direct_arrival_results (
  scenario text PRIMARY KEY,
  ok boolean NOT NULL,
  detail text
);

DO $contract$
DECLARE
  v_store uuid;
  v_auth uuid;
  v_user uuid;
  v_menu uuid;
  v_session uuid := gen_random_uuid();
  v_secret_hash text := replace(gen_random_uuid()::text, '-', '') ||
    replace(gen_random_uuid()::text, '-', '');
  v_client uuid := gen_random_uuid();
  v_submit jsonb;
  v_replay jsonb;
  v_request uuid;
  v_baseline jsonb;
  v_catchup jsonb;
  v_cursor jsonb;
  v_events_before bigint;
  v_events_after bigint;
  v_blocked boolean := false;
  v_rollback_client uuid := gen_random_uuid();
BEGIN
  SELECT store_id, auth_id, user_id, menu_item_id
  INTO v_store, v_auth, v_user, v_menu
  FROM direct_delivery_test.constants LIMIT 1;
  PERFORM direct_delivery_test.set_actor();

  v_baseline := public.direct_order_arrival_alerts_after(
    v_store, NULL, NULL, 100
  );
  v_cursor := v_baseline->'next_cursor';
  INSERT INTO _direct_arrival_results VALUES (
    'first device establishes a server cursor without historical alerts',
    v_baseline->'items'='[]'::jsonb
      AND (v_baseline->>'pending_count')::integer=0
      AND (SELECT count(*) FROM jsonb_object_keys(v_baseline))=4
      AND (SELECT count(*) FROM jsonb_object_keys(v_cursor))=2,
    'baseline response is payload-minimal'
  );

  SELECT count(*) INTO v_events_before
  FROM public.pos_live_events event
  WHERE event.restaurant_id=v_store AND event.domain='direct_orders';

  INSERT INTO public.direct_order_sessions(
    id, restaurant_id, secret_hash, locale
  ) VALUES (v_session, v_store, v_secret_hash, 'ko');
  v_submit := public.direct_order_public_submit(
    v_session,
    v_secret_hash,
    v_client,
    jsonb_build_object(
      'locale', 'ko',
      'items', jsonb_build_array(jsonb_build_object(
        'menu_item_id', v_menu,
        'quantity', 1,
        'note', '민감한 품목 메모'
      )),
      'customer_note', '민감한 고객 메모',
      'address', jsonb_build_object(
        'customer_name', '민감한 이름',
        'customer_phone', '+84909999999',
        'formatted_address', '민감한 전체 주소',
        'detail_address', '민감한 상세 주소',
        'latitude', 10.775,
        'longitude', 106.704,
        'district', 'Quận 1',
        'ward', 'Bến Nghé',
        'address_source', 'map_pin',
        'location_verified', true
      )
    )
  );
  v_request := (v_submit->>'request_id')::uuid;

  v_replay := public.direct_order_public_submit(
    v_session,
    v_secret_hash,
    v_client,
    jsonb_build_object(
      'locale', 'ko',
      'items', jsonb_build_array(jsonb_build_object(
        'menu_item_id', v_menu, 'quantity', 1
      )),
      'address', jsonb_build_object(
        'customer_name', 'replay',
        'customer_phone', '+84901111111',
        'formatted_address', 'replay',
        'detail_address', 'replay',
        'latitude', 10.775,
        'longitude', 106.704,
        'address_source', 'map_pin',
        'location_verified', true
      )
    )
  );
  SELECT count(*) INTO v_events_after
  FROM public.pos_live_events event
  WHERE event.restaurant_id=v_store AND event.domain='direct_orders';
  INSERT INTO _direct_arrival_results VALUES (
    'insert emits once and idempotent submit replay emits zero',
    v_replay->>'request_id'=v_request::text
      AND v_replay->>'idempotent'='true'
      AND v_events_after=v_events_before+1
      AND EXISTS (
        SELECT 1 FROM public.pos_live_events event
        WHERE event.restaurant_id=v_store
          AND event.domain='direct_orders'
          AND event.source_table='direct_order_requests'
          AND event.event_type='INSERT'
      ),
    'payload-free pos_live_events row only'
  );

  v_catchup := public.direct_order_arrival_alerts_after(
    v_store,
    (v_cursor->>'created_at')::timestamptz,
    (v_cursor->>'request_id')::uuid,
    100
  );
  INSERT INTO _direct_arrival_results VALUES (
    'catch-up returns only cursor state and pending count',
    jsonb_array_length(v_catchup->'items')=1
      AND v_catchup->'items'->0->>'request_id'=v_request::text
      AND v_catchup->'items'->0->>'state'='awaiting_quote'
      AND (SELECT count(*) FROM jsonb_object_keys(v_catchup->'items'->0))=3
      AND (v_catchup->>'pending_count')::integer=1
      AND (v_catchup::text NOT LIKE '%민감한%')
      AND (v_catchup::text NOT LIKE '%locale%'),
    'no customer locale address chat note menu or proof payload'
  );

  PERFORM direct_delivery_test.set_actor();
  PERFORM public.direct_order_staff_quote(v_store, v_request, 25000, NULL);
  PERFORM public.direct_order_staff_message(v_store, v_request, 'cashier text');
  PERFORM public.direct_order_public_message(
    v_session, v_secret_hash, v_request, 'customer text'
  );
  PERFORM public.direct_order_public_cancel(
    v_session, v_secret_hash, v_request
  );
  INSERT INTO _direct_arrival_results VALUES (
    'quote chat and cancel updates emit no arrival event',
    (SELECT count(*) FROM public.pos_live_events event
     WHERE event.restaurant_id=v_store AND event.domain='direct_orders')
      =v_events_after,
    'arrival trigger is INSERT-only'
  );

  v_events_before := v_events_after;
  BEGIN
    INSERT INTO public.direct_order_sessions(
      restaurant_id, secret_hash, locale
    ) VALUES (
      v_store,
      replace(gen_random_uuid()::text, '-', '') ||
        replace(gen_random_uuid()::text, '-', ''),
      'vi'
    ) RETURNING id, secret_hash INTO v_session, v_secret_hash;
    PERFORM public.direct_order_public_submit(
      v_session,
      v_secret_hash,
      v_rollback_client,
      jsonb_build_object(
        'locale', 'vi',
        'items', jsonb_build_array(jsonb_build_object(
          'menu_item_id', v_menu, 'quantity', 1
        )),
        'address', jsonb_build_object(
          'customer_name', 'Rollback',
          'customer_phone', '+84901234567',
          'formatted_address', 'Rollback address',
          'detail_address', 'Rollback detail',
          'latitude', 10.775,
          'longitude', 106.704,
          'address_source', 'search',
          'location_verified', true
        )
      )
    );
    RAISE EXCEPTION 'DIRECT_ORDER_ALERT_TEST_ROLLBACK';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM NOT LIKE '%DIRECT_ORDER_ALERT_TEST_ROLLBACK%' THEN RAISE; END IF;
  END;
  INSERT INTO _direct_arrival_results VALUES (
    'rolled-back submit leaves no event and no request',
    NOT EXISTS (
      SELECT 1 FROM public.direct_order_requests
      WHERE client_request_id=v_rollback_client
    ) AND (SELECT count(*) FROM public.pos_live_events event
           WHERE event.restaurant_id=v_store AND event.domain='direct_orders')
          =v_events_before,
    'trigger row shares the request transaction'
  );

  UPDATE public.users SET role='kitchen' WHERE id=v_user;
  BEGIN
    PERFORM public.direct_order_arrival_alerts_after(v_store, NULL, NULL, 100);
  EXCEPTION WHEN OTHERS THEN
    v_blocked := SQLERRM LIKE '%DIRECT_ORDER_FORBIDDEN%';
  END;
  UPDATE public.users SET role='cashier' WHERE id=v_user;
  INSERT INTO _direct_arrival_results VALUES (
    'catch-up RPC is cashier-only and store-scoped',
    v_blocked,
    'kitchen and other roles cannot read the alert cursor feed'
  );

  INSERT INTO _direct_arrival_results VALUES (
    'trigger contract is after insert only',
    EXISTS (
      SELECT 1 FROM pg_trigger trigger_row
      WHERE trigger_row.tgrelid='public.direct_order_requests'::regclass
        AND trigger_row.tgname='direct_order_arrival_live_event'
        AND pg_get_triggerdef(trigger_row.oid) LIKE '%AFTER INSERT%'
        AND pg_get_triggerdef(trigger_row.oid) NOT LIKE '%UPDATE%'
        AND pg_get_triggerdef(trigger_row.oid) NOT LIKE '%DELETE%'
    ),
    'no quote proof approve reject cancel update can create an arrival signal'
  );
END;
$contract$;

DO $assert$
DECLARE v_failures text;
BEGIN
  SELECT string_agg(scenario || ': ' || detail, E'\n' ORDER BY scenario)
  INTO v_failures FROM _direct_arrival_results WHERE NOT ok;
  IF v_failures IS NOT NULL THEN
    RAISE EXCEPTION E'DIRECT_DELIVERY_ARRIVAL_ALERT_CONTRACT_FAILED:\n%',
      v_failures;
  END IF;
END;
$assert$;

SELECT 'DIRECT_DELIVERY_ARRIVAL_ALERT_CONTRACT_PASS' AS result,
       count(*) AS scenarios
FROM _direct_arrival_results;

ROLLBACK;
