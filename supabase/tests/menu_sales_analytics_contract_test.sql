-- Menu-sales analytics contract test. Runs inside a transaction and rolls back.
--
-- Run against a fully migrated local database:
--   psql "$DB_URL" -f supabase/tests/menu_sales_analytics_contract_test.sql

BEGIN;

CREATE TEMP TABLE _menu_sales_results (
  scenario text,
  ok boolean,
  detail text
);

DO $contract$
DECLARE
  v_actor uuid;
  v_store uuid;
  v_result jsonb;
  v_top jsonb;
  v_hour_10 jsonb;
  v_snapshot uuid;
  v_waiter uuid := 'a11a0000-0000-4000-8000-0000000000a1';
  v_immutable boolean := false;
  v_forbidden boolean := false;
BEGIN
  SELECT auth_user.id, app_user.restaurant_id
  INTO v_actor, v_store
  FROM auth.users auth_user
  JOIN public.users app_user ON app_user.auth_id = auth_user.id
  WHERE app_user.role = 'super_admin'
    AND app_user.is_active
    AND app_user.restaurant_id IS NOT NULL
  LIMIT 1;

  IF v_actor IS NULL THEN
    SELECT restaurant.id
    INTO v_store
    FROM public.restaurants restaurant
    WHERE restaurant.is_active
    LIMIT 1;

    IF v_store IS NULL THEN
      RAISE EXCEPTION
        'MENU_SALES_ANALYTICS_CONTRACT requires a seeded restaurant';
    END IF;

    v_actor := 'a11a0000-0000-4000-8000-0000000000a0';
    INSERT INTO auth.users (id, email)
    VALUES (v_actor, 'menu.sales.contract.super@globos.test');
    INSERT INTO public.users (
      auth_id, restaurant_id, role, full_name, is_active
    ) VALUES (
      v_actor, v_store, 'super_admin', 'Menu Sales Contract Super', true
    );
  END IF;

  INSERT INTO public.menu_items (
    id, restaurant_id, name, price, is_available
  ) VALUES
    ('a11a0000-0000-4000-8000-000000000001', v_store, 'Menu A', 100, true),
    ('a11a0000-0000-4000-8000-000000000002', v_store, 'Menu B', 150, true);

  INSERT INTO public.orders (
    id, restaurant_id, sales_channel, status, created_by, created_at
  ) VALUES
    (
      'a11a0000-0000-4000-8000-000000000101', v_store,
      'dine_in', 'completed', v_actor, '2099-01-01 03:00:00+00'
    ),
    (
      'a11a0000-0000-4000-8000-000000000102', v_store,
      'takeaway', 'completed', v_actor, '2099-01-01 04:00:00+00'
    );

  INSERT INTO public.order_items (
    id, restaurant_id, order_id, menu_item_id, item_type,
    display_name, label, unit_price, quantity, status,
    paying_amount_inc_tax, is_service_item, created_at
  ) VALUES
    (
      'a11a0000-0000-4000-8000-000000000201', v_store,
      'a11a0000-0000-4000-8000-000000000101',
      'a11a0000-0000-4000-8000-000000000001', 'menu_item',
      'Menu A Old', 'Menu A Old', 100, 2, 'served', 200, false,
      '2099-01-01 03:01:00+00'
    ),
    (
      'a11a0000-0000-4000-8000-000000000202', v_store,
      'a11a0000-0000-4000-8000-000000000101',
      'a11a0000-0000-4000-8000-000000000002', 'menu_item',
      'Menu B', 'Menu B', 150, 1, 'served', 150, false,
      '2099-01-01 03:02:00+00'
    ),
    (
      'a11a0000-0000-4000-8000-000000000203', v_store,
      'a11a0000-0000-4000-8000-000000000102',
      'a11a0000-0000-4000-8000-000000000001', 'menu_item',
      'Menu A New', 'Menu A New', 100, 1, 'served', 100, false,
      '2099-01-01 04:01:00+00'
    ),
    (
      'a11a0000-0000-4000-8000-000000000204', v_store,
      'a11a0000-0000-4000-8000-000000000102',
      'a11a0000-0000-4000-8000-000000000002', 'menu_item',
      'Menu B', 'Menu B', 150, 5, 'cancelled', 750, false,
      '2099-01-01 04:02:00+00'
    ),
    (
      'a11a0000-0000-4000-8000-000000000205', v_store,
      'a11a0000-0000-4000-8000-000000000102',
      'a11a0000-0000-4000-8000-000000000002', 'menu_item',
      'Menu B', 'Menu B', 150, 3, 'served', 450, true,
      '2099-01-01 04:03:00+00'
    );

  INSERT INTO public.payments (
    id, restaurant_id, order_id, amount, amount_portion,
    method, processed_by, is_revenue, created_at
  ) VALUES
    (
      'a11a0000-0000-4000-8000-000000000301', v_store,
      'a11a0000-0000-4000-8000-000000000101', 100, 100,
      'CASH', v_actor, true, '2099-01-01 03:10:00+00'
    ),
    (
      'a11a0000-0000-4000-8000-000000000302', v_store,
      'a11a0000-0000-4000-8000-000000000101', 250, 250,
      'CREDITCARD', v_actor, true, '2099-01-01 03:15:00+00'
    ),
    (
      'a11a0000-0000-4000-8000-000000000303', v_store,
      'a11a0000-0000-4000-8000-000000000102', 100, 100,
      'CASH', v_actor, true, '2099-01-01 04:10:00+00'
    );

  INSERT INTO public.payment_adjustments (
    id, payment_id, order_id, restaurant_id, adjustment_type,
    amount, method, reason, created_by, created_at
  ) VALUES (
    'a11a0000-0000-4000-8000-000000000401',
    'a11a0000-0000-4000-8000-000000000303',
    'a11a0000-0000-4000-8000-000000000102', v_store,
    'refund', 20, 'CASH', 'contract test', v_actor,
    '2099-01-01 04:20:00+00'
  );

  PERFORM set_config(
    'request.jwt.claims',
    json_build_object('sub', v_actor, 'role', 'authenticated')::text,
    true
  );

  v_result := public.get_store_menu_sales_analytics(
    v_store,
    '2099-01-01 00:00:00+07',
    '2099-01-02 00:00:00+07'
  );

  SELECT row_value
  INTO v_top
  FROM jsonb_array_elements(v_result->'menu_rows') row_value
  WHERE row_value->>'menu_key' =
    'a11a0000-0000-4000-8000-000000000001';

  SELECT row_value
  INTO v_hour_10
  FROM jsonb_array_elements(v_result->'hour_rows') row_value
  WHERE (row_value->>'hour')::integer = 10;

  INSERT INTO _menu_sales_results VALUES
    (
      'split payments count one order',
      (v_result->'summary'->>'order_count')::integer = 2,
      v_result->'summary'->>'order_count'
    ),
    (
      'cancelled and service lines excluded',
      (v_result->'summary'->>'sold_quantity')::integer = 4
        AND (v_result->'summary'->>'menu_sales_amount')::numeric = 450,
      v_result->'summary'::text
    ),
    (
      'stable identity merges renamed menu',
      (v_top->>'rank')::integer = 1
        AND v_top->>'display_name' = 'Menu A New'
        AND (v_top->>'name_changed_in_period')::boolean
        AND (v_top->>'sold_quantity')::integer = 3
        AND (v_top->>'order_count')::integer = 2,
      COALESCE(v_top::text, 'missing')
    ),
    (
      'channel quantities follow order channel',
      (v_top->>'dine_in_quantity')::integer = 2
        AND (v_top->>'takeaway_quantity')::integer = 1,
      COALESCE(v_top::text, 'missing')
    ),
    (
      'HCM payment hour and complete series',
      jsonb_array_length(v_result->'hour_rows') = 24
        AND (v_hour_10->>'sold_quantity')::integer = 3,
      COALESCE(v_hour_10::text, 'missing')
    ),
    (
      'refunds disclosed without estimated item allocation',
      (v_result->'summary'->>'unallocated_adjustment_count')::integer = 1
        AND (
          v_result->'summary'->>'unallocated_adjustment_amount'
        )::numeric = 20
        AND v_result->'scope'->>'adjustment_allocation' = 'unallocated',
      v_result->'summary'::text
    );

  SELECT menu_item_id_snapshot
  INTO v_snapshot
  FROM public.order_items
  WHERE id = 'a11a0000-0000-4000-8000-000000000201';

  BEGIN
    UPDATE public.order_items
    SET menu_item_id_snapshot =
      'a11a0000-0000-4000-8000-000000000002'
    WHERE id = 'a11a0000-0000-4000-8000-000000000201';
  EXCEPTION WHEN OTHERS THEN
    v_immutable := SQLERRM LIKE '%ORDER_ITEM_MENU_IDENTITY_IMMUTABLE%';
  END;

  INSERT INTO _menu_sales_results VALUES (
    'menu identity is captured and immutable',
    v_snapshot = 'a11a0000-0000-4000-8000-000000000001'
      AND v_immutable,
    COALESCE(v_snapshot::text, 'missing')
  );

  INSERT INTO auth.users (id, email)
  VALUES (v_waiter, 'menu.sales.contract.waiter@globos.test');
  INSERT INTO public.users (
    auth_id, restaurant_id, role, full_name, is_active
  ) VALUES (
    v_waiter, v_store, 'waiter', 'Menu Sales Contract Waiter', true
  );
  PERFORM set_config(
    'request.jwt.claims',
    json_build_object('sub', v_waiter, 'role', 'authenticated')::text,
    true
  );
  BEGIN
    PERFORM public.get_store_menu_sales_analytics(
      v_store,
      '2099-01-01 00:00:00+07',
      '2099-01-02 00:00:00+07'
    );
  EXCEPTION WHEN OTHERS THEN
    v_forbidden := true;
  END;
  INSERT INTO _menu_sales_results VALUES (
    'non-admin actor is forbidden',
    v_forbidden,
    CASE WHEN v_forbidden THEN 'blocked' ELSE 'unexpectedly allowed' END
  );
END;
$contract$;

DO $report$
DECLARE
  v_report text;
  v_failures integer;
BEGIN
  SELECT
    string_agg(
      (CASE WHEN ok THEN 'PASS ' ELSE 'FAIL ' END) || scenario ||
        CASE WHEN ok THEN '' ELSE ' :: ' || detail END,
      ' | ' ORDER BY scenario
    ),
    count(*) FILTER (WHERE NOT ok)
  INTO v_report, v_failures
  FROM _menu_sales_results;

  IF v_failures > 0 THEN
    RAISE EXCEPTION 'MENU_SALES_ANALYTICS_CONTRACT fail=% >>> %',
      v_failures, v_report;
  END IF;

  RAISE NOTICE 'MENU_SALES_ANALYTICS_CONTRACT fail=% >>> %',
    v_failures, v_report;
END;
$report$;

ROLLBACK;
