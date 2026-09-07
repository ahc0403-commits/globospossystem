-- Manual address entry replaces map-based delivery address selection.
-- Existing order/address/coordinate history is retained. No provider calls or
-- fake zero/store coordinates are used for new manually entered addresses.
ALTER TABLE public.direct_order_request_addresses
  ALTER COLUMN latitude DROP NOT NULL,
  ALTER COLUMN longitude DROP NOT NULL;
ALTER TABLE public.direct_order_request_addresses
  DROP CONSTRAINT direct_order_request_addresses_address_source_check;
ALTER TABLE public.direct_order_request_addresses
  ADD CONSTRAINT direct_order_request_addresses_address_source_check
    CHECK (address_source IN ('manual', 'search', 'map_pin')),
  ADD CONSTRAINT direct_order_address_location_mode_valid CHECK (
    (address_source = 'manual' AND latitude IS NULL AND longitude IS NULL
      AND google_place_id IS NULL AND location_verified = false)
    OR (address_source IN ('search', 'map_pin')
      AND latitude IS NOT NULL AND longitude IS NOT NULL)
  );

CREATE OR REPLACE FUNCTION public.direct_order_public_submit(
  p_session_id uuid,
  p_secret_hash text,
  p_client_request_id uuid,
  p_payload jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
AS $$
DECLARE
  v_session public.direct_order_sessions%ROWTYPE;
  v_storefront public.direct_order_storefronts%ROWTYPE;
  v_request public.direct_order_requests%ROWTYPE;
  v_existing public.direct_order_requests%ROWTYPE;
  v_address jsonb;
  v_item jsonb;
  v_menu public.menu_items%ROWTYPE;
  v_item_count integer := 0;
  v_total_quantity integer := 0;
  v_reference text;
  v_local_time time;
BEGIN
  IF p_client_request_id IS NULL
     OR p_payload IS NULL
     OR jsonb_typeof(p_payload) <> 'object'
     OR jsonb_typeof(p_payload->'items') <> 'array'
     OR jsonb_array_length(p_payload->'items') NOT BETWEEN 1 AND 50
     OR jsonb_typeof(p_payload->'address') <> 'object'
     OR COALESCE(p_payload->>'locale', '') NOT IN ('ko', 'vi', 'en') THEN
    RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_INPUT_INVALID';
  END IF;

  v_session := public.direct_order_validate_session(
    p_session_id, p_secret_hash
  );

  SELECT * INTO v_existing
  FROM public.direct_order_requests request_row
  WHERE request_row.client_request_id = p_client_request_id;
  IF FOUND THEN
    IF v_existing.session_id <> v_session.id
       OR v_existing.restaurant_id <> v_session.restaurant_id THEN
      RAISE EXCEPTION 'DIRECT_ORDER_REQUEST_INPUT_INVALID';
    END IF;
    RETURN jsonb_build_object(
      'request_id', v_existing.id,
      'reference_code', v_existing.reference_code,
      'state', v_existing.state,
      'idempotent', true
    );
  END IF;

  SELECT * INTO v_storefront
  FROM public.direct_order_storefronts storefront
  WHERE storefront.restaurant_id = v_session.restaurant_id
    AND storefront.is_enabled = true
  FOR SHARE;

  IF NOT FOUND OR v_storefront.is_paused THEN
    RAISE EXCEPTION 'DIRECT_ORDER_STOREFRONT_PAUSED';
  END IF;

  v_local_time := (now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::time;
  IF v_local_time < v_storefront.ordering_starts_at
     OR v_local_time >= v_storefront.ordering_cutoff_at THEN
    RAISE EXCEPTION 'DIRECT_ORDER_OUTSIDE_HOURS';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.direct_order_requests open_request
    WHERE open_request.session_id = p_session_id
      AND open_request.state IN (
        'awaiting_quote', 'quoted', 'awaiting_payment_review'
      )
  ) THEN
    RAISE EXCEPTION 'DIRECT_ORDER_OPEN_REQUEST_EXISTS';
  END IF;

  v_address := p_payload->'address';
  IF char_length(btrim(COALESCE(v_address->>'customer_name', ''))) NOT BETWEEN 1 AND 100
     OR COALESCE(v_address->>'customer_phone', '') !~ '^[+]?[0-9][0-9 -]{7,19}$'
     OR char_length(btrim(COALESCE(v_address->>'formatted_address', ''))) NOT BETWEEN 3 AND 500
     OR char_length(btrim(COALESCE(v_address->>'detail_address', ''))) NOT BETWEEN 1 AND 300 THEN
    RAISE EXCEPTION 'DIRECT_ORDER_ADDRESS_INVALID';
  END IF;

  IF v_address->>'address_source' = 'manual' THEN
    -- A typed address has no verified location. Never manufacture coordinates
    -- or reuse a stale pin when the customer edits a previously saved address.
    IF v_address->>'latitude' IS NOT NULL
       OR v_address->>'longitude' IS NOT NULL
       OR NULLIF(btrim(COALESCE(v_address->>'google_place_id', '')), '') IS NOT NULL
       OR COALESCE(v_address->>'location_verified', 'false') <> 'false' THEN
      RAISE EXCEPTION 'DIRECT_ORDER_ADDRESS_INVALID';
    END IF;
  ELSIF COALESCE(v_address->>'address_source', '') NOT IN ('search', 'map_pin')
     OR COALESCE(v_address->>'location_verified', 'false') <> 'true'
     OR v_address->>'latitude' IS NULL
     OR v_address->>'longitude' IS NULL THEN
    -- Preserve in-flight legacy client compatibility without relaxing its
    -- existing location requirements.
    RAISE EXCEPTION 'DIRECT_ORDER_ADDRESS_INVALID';
  END IF;

  v_reference := 'D' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));

  INSERT INTO public.direct_order_requests(
    restaurant_id, session_id, client_request_id, reference_code,
    state, locale, customer_note
  ) VALUES (
    v_session.restaurant_id,
    v_session.id,
    p_client_request_id,
    v_reference,
    'awaiting_quote',
    COALESCE(NULLIF(p_payload->>'locale', ''), v_session.locale),
    NULLIF(btrim(COALESCE(p_payload->>'customer_note', '')), '')
  ) RETURNING * INTO v_request;

  FOR v_item IN SELECT value FROM jsonb_array_elements(p_payload->'items')
  LOOP
    IF (v_item->>'menu_item_id') IS NULL
       OR COALESCE((v_item->>'quantity')::integer, 0) NOT BETWEEN 1 AND 50 THEN
      RAISE EXCEPTION 'DIRECT_ORDER_ITEM_INVALID';
    END IF;

    SELECT * INTO v_menu
    FROM public.menu_items menu
    WHERE menu.id = (v_item->>'menu_item_id')::uuid
      AND menu.restaurant_id = v_session.restaurant_id
      AND menu.is_available = true
      AND menu.is_visible_public = true
      AND COALESCE(menu.combo_drink_choice_count, 0) = 0;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'DIRECT_ORDER_MENU_UNAVAILABLE';
    END IF;

    INSERT INTO public.direct_order_request_items(
      request_id, restaurant_id, menu_item_id, display_name,
      name_ko, name_vi, name_en, vat_category, unit_price, quantity,
      item_note, sort_order
    ) VALUES (
      v_request.id,
      v_request.restaurant_id,
      v_menu.id,
      v_menu.name,
      COALESCE(NULLIF(v_menu.name_ko, ''), v_menu.name),
      COALESCE(NULLIF(v_menu.name_vi, ''), v_menu.name),
      COALESCE(NULLIF(v_menu.name_en, ''), v_menu.name),
      COALESCE(v_menu.vat_category, 'food'),
      v_menu.price,
      (v_item->>'quantity')::integer,
      NULLIF(btrim(COALESCE(v_item->>'note', '')), ''),
      v_item_count
    );

    v_item_count := v_item_count + 1;
    v_total_quantity := v_total_quantity + (v_item->>'quantity')::integer;
  END LOOP;

  IF v_total_quantity > 100 THEN
    RAISE EXCEPTION 'DIRECT_ORDER_QUANTITY_LIMIT';
  END IF;

  INSERT INTO public.direct_order_request_addresses(
    request_id, restaurant_id, customer_name, customer_phone,
    formatted_address, detail_address, latitude, longitude,
    google_place_id, district, ward, address_source, location_verified
  ) VALUES (
    v_request.id,
    v_request.restaurant_id,
    btrim(v_address->>'customer_name'),
    btrim(v_address->>'customer_phone'),
    btrim(v_address->>'formatted_address'),
    btrim(v_address->>'detail_address'),
    (v_address->>'latitude')::numeric,
    (v_address->>'longitude')::numeric,
    NULLIF(btrim(COALESCE(v_address->>'google_place_id', '')), ''),
    NULLIF(btrim(COALESCE(v_address->>'district', '')), ''),
    NULLIF(btrim(COALESCE(v_address->>'ward', '')), ''),
    v_address->>'address_source',
    v_address->>'address_source' <> 'manual'
  );

  IF v_address->>'address_source' <> 'manual' THEN
    INSERT INTO public.direct_order_location_facts(
      request_id, restaurant_id, district, ward,
      coarse_latitude, coarse_longitude, requested_at
    ) VALUES (
      v_request.id,
      v_request.restaurant_id,
      NULLIF(btrim(COALESCE(v_address->>'district', '')), ''),
      NULLIF(btrim(COALESCE(v_address->>'ward', '')), ''),
      round((v_address->>'latitude')::numeric, 3),
      round((v_address->>'longitude')::numeric, 3),
      v_request.created_at
    );
  END IF;

  INSERT INTO public.direct_order_messages(
    request_id, restaurant_id, sender_type, message_type, body
  ) VALUES (
    v_request.id,
    v_request.restaurant_id,
    'system',
    'system',
    'DIRECT_ORDER_REQUEST_RECEIVED'
  );

  RETURN jsonb_build_object(
    'request_id', v_request.id,
    'reference_code', v_request.reference_code,
    'state', v_request.state,
    'idempotent', false
  );
END;
$$;

REVOKE ALL ON FUNCTION public.direct_order_public_submit(uuid, text, uuid, jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.direct_order_public_submit(uuid, text, uuid, jsonb)
  TO service_role;
