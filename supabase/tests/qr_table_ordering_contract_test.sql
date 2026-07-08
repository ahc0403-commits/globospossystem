-- qr_table_ordering_contract_test.sql
-- Prod-safe rollback smoke for QR Table Ordering V1.
--
-- Run against a fully migrated database:
--   psql "$DB_URL" -f supabase/tests/qr_table_ordering_contract_test.sql

\set ON_ERROR_STOP on

BEGIN;

CREATE TEMP TABLE _qr_results (
  scenario text,
  ok boolean,
  detail text
);

DO $seed$
DECLARE
  v_store uuid := 'f1000000-0000-4000-8000-000000000001';
  v_table uuid := 'f1000000-0000-4000-8000-0000000000b1';
  v_auth uuid := 'f1000000-0000-4000-8000-0000000000a1';
  v_user uuid := 'f1000000-0000-4000-8000-0000000000c1';
  v_public_item uuid := 'f1000000-0000-4000-8000-0000000000d1';
  v_hidden_item uuid := 'f1000000-0000-4000-8000-0000000000d2';
  v_client uuid := 'f1000000-0000-4000-8000-0000000000e1';
  v_menu jsonb;
  v_result jsonb;
  v_replay jsonb;
  v_order uuid;
  v_price numeric;
  v_confirmation_jobs int;
  v_order_count int;
  v_search jsonb;
  v_blocked boolean := false;
  v_discount_id uuid := 'f1000000-0000-4000-8000-0000000000f1';
  v_discount_status text;
  v_order_status text;
BEGIN
  INSERT INTO public.restaurants (id, name, address, is_active, brand_id, tax_entity_id)
  SELECT v_store, 'QR Contract Store', 'test', true, r.brand_id, r.tax_entity_id
  FROM public.restaurants r
  WHERE r.brand_id IS NOT NULL
    AND r.tax_entity_id IS NOT NULL
  LIMIT 1;

  INSERT INTO auth.users (id, email)
  VALUES (v_auth, 'qr.contract.cashier@globos.test')
  ON CONFLICT (id) DO NOTHING;

  INSERT INTO public.users (id, auth_id, restaurant_id, role, full_name, is_active)
  VALUES (v_user, v_auth, v_store, 'cashier', 'QR Contract Cashier', true)
  ON CONFLICT (id) DO UPDATE
  SET auth_id = EXCLUDED.auth_id,
      restaurant_id = EXCLUDED.restaurant_id,
      role = EXCLUDED.role,
      is_active = true;

  INSERT INTO public.user_store_access (user_id, store_id, is_primary, is_active, source_type)
  VALUES (v_user, v_store, true, true, 'direct')
  ON CONFLICT DO NOTHING;

  INSERT INTO public.tables (id, restaurant_id, table_number, seat_count, status, floor_label)
  VALUES (v_table, v_store, 'QR-7', 4, 'available', '2F')
  ON CONFLICT (id) DO UPDATE
  SET status = 'available',
      floor_label = '2F';

  INSERT INTO public.menu_items (
    id,
    restaurant_id,
    name,
    price,
    is_available,
    is_visible_public
  )
  VALUES
    (v_public_item, v_store, 'QR Public Pho', 90000, true, true),
    (v_hidden_item, v_store, 'QR Hidden Wine', 120000, true, false)
  ON CONFLICT (id) DO UPDATE
  SET price = EXCLUDED.price,
      is_available = EXCLUDED.is_available,
      is_visible_public = EXCLUDED.is_visible_public;

  INSERT INTO public.printer_destinations (
    restaurant_id,
    name,
    ip,
    port,
    purpose,
    floor_label,
    is_active
  )
  VALUES
    (v_store, 'QR Kitchen', '192.0.2.10', 9100, 'kitchen', NULL, true),
    (v_store, 'QR Floor 2F', '192.0.2.11', 9100, 'floor', '2F', true);

  INSERT INTO public.table_qr_tokens (restaurant_id, table_id, token, is_active)
  VALUES (v_store, v_table, 'qr-contract-token', true);
  INSERT INTO public.table_qr_tokens (restaurant_id, table_id, token, is_active, rotated_at)
  VALUES (v_store, v_table, 'qr-rotated-token', false, now());

  v_menu := public.qr_get_menu('qr-contract-token');
  INSERT INTO _qr_results
  VALUES (
    'QR menu filters hidden items',
    jsonb_array_length(v_menu->'items') = 1
      AND (v_menu::text LIKE '%QR Public Pho%')
      AND (v_menu::text NOT LIKE '%QR Hidden Wine%'),
    v_menu::text
  );

  v_blocked := false;
  BEGIN
    PERFORM public.qr_get_menu('qr-rotated-token');
  EXCEPTION WHEN OTHERS THEN
    v_blocked := SQLERRM LIKE '%QR_TOKEN_INVALID%';
  END;
  INSERT INTO _qr_results
  VALUES ('QR rotated token blocked', v_blocked, 'rotated token guard');

  UPDATE public.restaurants SET is_active = false WHERE id = v_store;
  v_blocked := false;
  BEGIN
    PERFORM public.qr_get_menu('qr-contract-token');
  EXCEPTION WHEN OTHERS THEN
    v_blocked := SQLERRM LIKE '%QR_TOKEN_INVALID%';
  END;
  INSERT INTO _qr_results
  VALUES ('QR closed store token blocked', v_blocked, 'closed store guard');
  UPDATE public.restaurants SET is_active = true WHERE id = v_store;

  INSERT INTO _qr_results
  VALUES (
    'QR anon direct access remains constrained',
    NOT has_table_privilege('anon', 'public.table_qr_tokens', 'select')
      AND NOT has_table_privilege('anon', 'public.qr_order_batches', 'select')
      AND NOT has_table_privilege('anon', 'public.orders', 'insert')
      AND NOT has_function_privilege('anon', 'public.admin_generate_table_qr(uuid)', 'execute'),
    'anon grants'
  );

  v_blocked := false;
  BEGIN
    EXECUTE 'SET LOCAL ROLE anon';
    PERFORM public.create_order(v_store, v_table, '[]'::jsonb);
    EXECUTE 'RESET ROLE';
  EXCEPTION WHEN OTHERS THEN
    v_blocked := true;
    EXECUTE 'RESET ROLE';
  END;
  INSERT INTO _qr_results
  VALUES ('QR anon create_order runtime blocked', v_blocked, 'create_order guard');

  v_result := public.qr_place_order(
    'qr-contract-token',
    jsonb_build_array(
      jsonb_build_object(
        'menu_item_id',
        v_public_item,
        'quantity',
        2,
        'unit_price',
        1
      )
    ),
    v_client
  );
  v_order := (v_result->>'order_id')::uuid;

  SELECT unit_price INTO v_price
  FROM public.order_items
  WHERE order_id = v_order
    AND menu_item_id = v_public_item
  LIMIT 1;

  SELECT count(*) INTO v_confirmation_jobs
  FROM public.print_jobs
  WHERE order_id = v_order
    AND copy_type = 'confirmation';

  INSERT INTO _qr_results
  VALUES (
    'QR first order creates cashier-pay-later order',
    (SELECT order_source = 'qr' AND created_by IS NULL FROM public.orders WHERE id = v_order)
      AND (SELECT status = 'occupied' FROM public.tables WHERE id = v_table)
      AND v_price = 90000
      AND v_confirmation_jobs = 1,
    v_result::text
  );

  v_replay := public.qr_place_order(
    'qr-contract-token',
    jsonb_build_array(
      jsonb_build_object('menu_item_id', v_public_item, 'quantity', 2)
    ),
    v_client
  );

  SELECT count(*) INTO v_order_count
  FROM public.orders
  WHERE table_id = v_table
    AND order_source = 'qr';

  INSERT INTO _qr_results
  VALUES (
    'QR idempotent replay returns same result',
    (v_replay->>'order_code') = (v_result->>'order_code')
      AND v_order_count = 1,
    v_replay::text
  );

  UPDATE public.qr_order_batches
  SET created_at = now() - interval '30 seconds'
  WHERE client_order_id = v_client;

  UPDATE public.order_items
  SET status = 'served'
  WHERE order_id = v_order;
  UPDATE public.orders
  SET status = 'serving'
  WHERE id = v_order;
  INSERT INTO public.order_discounts (
    id,
    restaurant_id,
    order_id,
    discount_type,
    discount_mode,
    discount_value,
    discount_amount,
    reason,
    proof_storage_path,
    applied_by,
    status
  )
  VALUES (
    v_discount_id,
    v_store,
    v_order,
    'manual',
    'amount',
    1000,
    1000,
    'QR contract active discount',
    'qr-contract-proof.jpg',
    v_auth,
    'active'
  );

  PERFORM public.qr_place_order(
    'qr-contract-token',
    jsonb_build_array(
      jsonb_build_object('menu_item_id', v_public_item, 'quantity', 1)
    ),
    'f1000000-0000-4000-8000-0000000000e4'
  );
  SELECT status INTO v_order_status FROM public.orders WHERE id = v_order;
  SELECT status INTO v_discount_status FROM public.order_discounts WHERE id = v_discount_id;
  INSERT INTO _qr_results
  VALUES (
    'QR append demotes serving and voids active discount',
    v_order_status = 'confirmed' AND v_discount_status = 'voided',
    'order=' || COALESCE(v_order_status, 'null') || ', discount=' || COALESCE(v_discount_status, 'null')
  );

  v_blocked := false;
  BEGIN
    PERFORM public.qr_place_order(
      'qr-contract-token',
      jsonb_build_array(
        jsonb_build_object('menu_item_id', v_public_item, 'quantity', 1)
      ),
      'f1000000-0000-4000-8000-0000000000e5'
    );
  EXCEPTION WHEN OTHERS THEN
    v_blocked := SQLERRM LIKE '%QR_TOO_FREQUENT%';
  END;
  INSERT INTO _qr_results
  VALUES ('QR throttle blocks rapid new batch', v_blocked, 'throttle guard');

  v_blocked := false;
  BEGIN
    PERFORM public.qr_place_order(
      'qr-contract-token',
      jsonb_build_array(
        jsonb_build_object('menu_item_id', v_public_item, 'quantity', 21)
      ),
      'f1000000-0000-4000-8000-0000000000e6'
    );
  EXCEPTION WHEN OTHERS THEN
    v_blocked := SQLERRM LIKE '%QR_ITEMS_INVALID%';
  END;
  INSERT INTO _qr_results
  VALUES ('QR caps block invalid quantity', v_blocked, 'quantity cap guard');

  UPDATE public.qr_order_batches
  SET created_at = now() - interval '30 seconds'
  WHERE table_id = v_table;

  BEGIN
    PERFORM public.qr_place_order(
      'qr-contract-token',
      jsonb_build_array(
        jsonb_build_object('menu_item_id', v_hidden_item, 'quantity', 1)
      ),
      'f1000000-0000-4000-8000-0000000000e2'
    );
  EXCEPTION WHEN OTHERS THEN
    v_blocked := SQLERRM LIKE '%QR_MENU_ITEM_UNAVAILABLE%';
  END;
  INSERT INTO _qr_results
  VALUES ('QR hidden item blocked', v_blocked, 'hidden item guard');

  UPDATE public.qr_order_batches
  SET created_at = now() - interval '30 seconds'
  WHERE table_id = v_table;

  INSERT INTO public.payments (
    order_id,
    restaurant_id,
    amount,
    method,
    processed_by,
    is_revenue,
    amount_portion
  )
  VALUES (v_order, v_store, 1000, 'CASH', v_auth, true, 1000);

  v_blocked := false;
  BEGIN
    PERFORM public.qr_place_order(
      'qr-contract-token',
      jsonb_build_array(
        jsonb_build_object('menu_item_id', v_public_item, 'quantity', 1)
      ),
      'f1000000-0000-4000-8000-0000000000e3'
    );
  EXCEPTION WHEN OTHERS THEN
    v_blocked := SQLERRM LIKE '%QR_ORDER_PAYMENT_IN_PROGRESS%';
  END;
  INSERT INTO _qr_results
  VALUES ('QR append blocked during payment', v_blocked, 'payment guard');

  v_blocked := false;
  BEGIN
    PERFORM public.qr_get_menu('missing-token');
  EXCEPTION WHEN OTHERS THEN
    v_blocked := SQLERRM LIKE '%QR_TOKEN_INVALID%';
  END;
  INSERT INTO _qr_results
  VALUES ('QR invalid token blocked', v_blocked, 'token guard');

  PERFORM set_config(
    'request.jwt.claims',
    json_build_object('sub', v_auth, 'role', 'authenticated')::text,
    true
  );
  PERFORM set_config('request.jwt.claim.sub', v_auth::text, true);

  v_search := public.search_active_order_for_cashier(
    v_store,
    substring(v_order::text from 1 for 8)
  );
  INSERT INTO _qr_results
  VALUES (
    'Cashier search finds QR order by code',
    (v_search->>'id')::uuid = v_order
      AND v_search->'tables'->>'table_number' = 'QR-7',
    COALESCE(v_search::text, 'null')
  );
END;
$seed$;

DO $report$
DECLARE
  v_failures int;
  v_report text;
BEGIN
  SELECT
    count(*) FILTER (WHERE NOT ok),
    string_agg(
      (CASE WHEN ok THEN 'PASS ' ELSE 'FAIL ' END) || scenario ||
        CASE WHEN ok THEN '' ELSE ' :: ' || detail END,
      ' | '
      ORDER BY scenario
    )
  INTO v_failures, v_report
  FROM _qr_results;

  IF v_failures > 0 THEN
    RAISE EXCEPTION 'QR_TABLE_ORDERING_CONTRACT fail=% >>> %', v_failures, v_report;
  END IF;

  RAISE NOTICE 'QR_TABLE_ORDERING_CONTRACT fail=% >>> %', v_failures, v_report;
END;
$report$;

ROLLBACK;
