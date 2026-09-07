\set ON_ERROR_STOP on
DO $test$
DECLARE
  v_store uuid := gen_random_uuid();
  v_menu uuid := gen_random_uuid();
  v_session uuid;
  v_client uuid;
  v_result jsonb;
  v_retry jsonb;
  v_payload jsonb;
  v_address jsonb := jsonb_build_object(
    'customer_name', 'Test Recipient', 'customer_phone', '+84901234567',
    'formatted_address', 'Cantavil Premier, 1 Song Hanh, Ho Chi Minh',
    'detail_address', 'Floor 10, 1001', 'address_source', 'manual',
    'location_verified', false, 'latitude', NULL, 'longitude', NULL
  );
  v_invalid jsonb;
  v_before integer;
BEGIN
  IF current_database() <> 'codex_direct_manual' THEN
    RAISE EXCEPTION 'DISPOSABLE_DATABASE_REQUIRED';
  END IF;
  INSERT INTO restaurants VALUES (v_store);
  INSERT INTO direct_order_storefronts VALUES (v_store, true, false, '00:00', '23:59:59.999999', true);
  INSERT INTO menu_items(id,restaurant_id,name,name_ko,name_vi,name_en,vat_category,price,is_available,is_visible_public)
    VALUES (v_menu,v_store,'Fixture','Fixture','Fixture','Fixture','food',100000,true,true);
  v_payload := jsonb_build_object('locale','vi','items',jsonb_build_array(
    jsonb_build_object('menu_item_id',v_menu,'quantity',1)), 'address',v_address);
  INSERT INTO direct_order_sessions(restaurant_id,secret_hash) VALUES (v_store,repeat('a',64)) RETURNING id INTO v_session;
  v_client := gen_random_uuid();
  v_result := direct_order_public_submit(v_session,repeat('a',64),v_client,v_payload);
  IF NOT EXISTS (SELECT 1 FROM direct_order_request_addresses WHERE request_id=(v_result->>'request_id')::uuid
    AND formatted_address=v_address->>'formatted_address' AND latitude IS NULL AND longitude IS NULL
    AND google_place_id IS NULL AND NOT location_verified AND address_source='manual') THEN
    RAISE EXCEPTION 'MANUAL_ADDRESS_NOT_PERSISTED_CORRECTLY';
  END IF;
  IF EXISTS (SELECT 1 FROM direct_order_location_facts WHERE request_id=(v_result->>'request_id')::uuid) THEN
    RAISE EXCEPTION 'MANUAL_ADDRESS_CREATED_FAKE_LOCATION_FACT';
  END IF;
  v_retry := direct_order_public_submit(v_session,repeat('a',64),v_client,v_payload);
  IF v_retry->>'request_id' <> v_result->>'request_id' OR v_retry->>'idempotent' <> 'true' THEN
    RAISE EXCEPTION 'MANUAL_ADDRESS_IDEMPOTENCY_BROKEN';
  END IF;
  -- Separate session ensures address rejection, not the open-order guard.
  INSERT INTO direct_order_sessions(restaurant_id,secret_hash) VALUES (v_store,repeat('b',64)) RETURNING id INTO v_session;
  SELECT count(*) INTO v_before FROM direct_order_requests;
  FOREACH v_invalid IN ARRAY ARRAY[
    v_address || '{"formatted_address":" "}'::jsonb,
    v_address || '{"detail_address":""}'::jsonb,
    v_address || '{"customer_name":""}'::jsonb,
    v_address || '{"customer_phone":"abc"}'::jsonb,
    v_address || '{"latitude":0,"longitude":0}'::jsonb,
    v_address || '{"location_verified":true}'::jsonb,
    v_address || '{"google_place_id":"stale-google-place"}'::jsonb,
    v_address || '{"address_source":"invalid"}'::jsonb,
    v_address || '{"address_source":"search"}'::jsonb
  ] LOOP
    BEGIN
      PERFORM direct_order_public_submit(v_session,repeat('b',64),gen_random_uuid(),
        v_payload || jsonb_build_object('address',v_invalid));
      RAISE EXCEPTION 'INVALID_ADDRESS_ACCEPTED';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM <> 'DIRECT_ORDER_ADDRESS_INVALID' THEN RAISE; END IF;
    END;
  END LOOP;
  IF (SELECT count(*) FROM direct_order_requests) <> v_before THEN
    RAISE EXCEPTION 'INVALID_ADDRESS_LEFT_PARTIAL_ORDER';
  END IF;
  BEGIN
    PERFORM direct_order_public_submit(v_session,repeat('c',64),gen_random_uuid(),v_payload);
    RAISE EXCEPTION 'INVALID_SESSION_ACCEPTED';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'DIRECT_ORDER_SESSION_INVALID' THEN RAISE; END IF;
  END;
  UPDATE direct_order_storefronts SET is_paused=true WHERE restaurant_id=v_store;
  BEGIN
    PERFORM direct_order_public_submit(v_session,repeat('b',64),gen_random_uuid(),v_payload);
    RAISE EXCEPTION 'PAUSED_STOREFRONT_ACCEPTED';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'DIRECT_ORDER_STOREFRONT_PAUSED' THEN RAISE; END IF;
  END;
  UPDATE direct_order_storefronts SET is_paused=false WHERE restaurant_id=v_store;
  UPDATE direct_order_storefronts SET ordering_starts_at='00:00', ordering_cutoff_at='00:00'
    WHERE restaurant_id=v_store;
  BEGIN
    PERFORM direct_order_public_submit(v_session,repeat('b',64),gen_random_uuid(),v_payload);
    RAISE EXCEPTION 'ENFORCED_ORDERING_HOURS_IGNORED';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'DIRECT_ORDER_OUTSIDE_HOURS' THEN RAISE; END IF;
  END;
  -- The existing per-store pilot switch must remain effective after migration.
  UPDATE direct_order_storefronts SET ordering_hours_enforced=false WHERE restaurant_id=v_store;
  -- Cached old clients retain their original coordinate contract.
  v_result := direct_order_public_submit(v_session,repeat('b',64),gen_random_uuid(),
    v_payload || jsonb_build_object('address',v_address ||
      '{"address_source":"search","location_verified":true,"latitude":10.8,"longitude":106.7}'::jsonb));
  IF NOT EXISTS (SELECT 1 FROM direct_order_location_facts WHERE request_id=(v_result->>'request_id')::uuid
    AND coarse_latitude=10.8 AND coarse_longitude=106.7) THEN
    RAISE EXCEPTION 'LEGACY_LOCATION_COMPATIBILITY_BROKEN';
  END IF;
END;
$test$;
