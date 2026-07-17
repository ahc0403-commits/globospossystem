-- pilot_gate3_operational_audit.sql
-- Prod-safe rollback audit for the dedicated Gate 3 pilot fixture.
--
-- This script proves the gaps called out by the design-vs-code audit without
-- leaving orders, payments, adjustments, print jobs, or daily closings behind.

BEGIN;

CREATE TEMP TABLE _pilot_gate3_results (
  scenario text PRIMARY KEY,
  ok boolean NOT NULL,
  detail text
);

CREATE FUNCTION pg_temp.add_result(
  p_scenario text,
  p_ok boolean,
  p_detail text DEFAULT NULL
) RETURNS void
LANGUAGE sql AS $$
  INSERT INTO _pilot_gate3_results (scenario, ok, detail)
  VALUES (p_scenario, p_ok, p_detail)
  ON CONFLICT (scenario) DO UPDATE
  SET ok = EXCLUDED.ok,
      detail = EXCLUDED.detail;
$$;

CREATE FUNCTION pg_temp.act_as(p_auth uuid) RETURNS void
LANGUAGE sql AS $$
  SELECT set_config(
    'request.jwt.claims',
    json_build_object('sub', p_auth, 'role', 'authenticated')::text,
    true
  );
  SELECT set_config('request.jwt.claim.sub', p_auth::text, true);
$$;

DO $audit$
DECLARE
  v_store uuid := '90000000-0000-4000-8000-000000000301';
  v_table_1f uuid := '90000000-0000-4000-8000-000000000321';
  v_table_2f uuid := '90000000-0000-4000-8000-000000000322';
  v_menu_item uuid := '90000000-0000-4000-8000-000000000332';
  v_waiter_auth uuid := '90000000-0000-4000-8000-000000000311';
  v_cashier_auth uuid := '90000000-0000-4000-8000-000000000313';
  v_admin_auth uuid := '90000000-0000-4000-8000-000000000314';
  v_other_store uuid := '90000000-0000-4000-8000-000000000302';
  v_other_table uuid := '90000000-0000-4000-8000-000000000324';
  v_other_order uuid := '90000000-0000-4000-8000-000000000364';
  v_close_order uuid := '90000000-0000-4000-8000-000000000365';
  v_close_payment uuid := '90000000-0000-4000-8000-000000000366';
  v_qr_client uuid := '90000000-0000-4000-8000-0000000003c1';
  v_qr_result jsonb;
  v_qr_replay jsonb;
  v_qr_order uuid;
  v_close_result jsonb;
  v_adjustment public.payment_adjustments%ROWTYPE;
  v_denied boolean;
  v_over_refund_blocked boolean;
  v_brand uuid;
  v_tax_entity uuid;
  v_current_date date := (now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date;
BEGIN
  SELECT brand_id, tax_entity_id
  INTO v_brand, v_tax_entity
  FROM public.restaurants
  WHERE id = v_store;

  PERFORM pg_temp.add_result(
    'fixture store exists with cleanup metadata',
    EXISTS (
      SELECT 1
      FROM public.restaurants r
      JOIN public.restaurant_settings s ON s.restaurant_id = r.id
      WHERE r.id = v_store
        AND r.slug = 'pilot-gate3-fixture'
        AND r.is_active
        AND s.settings_json->>'fixture' = 'pilot_gate3'
        AND s.settings_json->>'qa_run_id' = 'pilot_gate3_fixture'
    ),
    'store/settings fixture metadata'
  );

  PERFORM pg_temp.add_result(
    'role accounts are scoped to fixture store',
    (
      SELECT count(*) = 6
      FROM public.users u
      JOIN public.user_store_access usa ON usa.user_id = u.id
      WHERE u.auth_id IN (
        v_waiter_auth,
        '90000000-0000-4000-8000-000000000312'::uuid,
        v_cashier_auth,
        v_admin_auth,
        '90000000-0000-4000-8000-000000000315'::uuid,
        '90000000-0000-4000-8000-000000000316'::uuid
      )
        AND u.restaurant_id = v_store
        AND u.primary_store_id = v_store
        AND u.is_active
        AND usa.store_id = v_store
        AND usa.is_active
    ),
    'public.users + user_store_access'
  );

  PERFORM pg_temp.add_result(
    'floor and printer routing shape is complete',
    (
      SELECT
        count(*) FILTER (WHERE p.purpose = 'kitchen') = 1
        AND count(*) FILTER (WHERE p.purpose = 'receipt') = 1
        AND count(*) FILTER (WHERE p.purpose = 'floor' AND p.floor_label = '1F') = 1
        AND count(*) FILTER (WHERE p.purpose = 'floor' AND p.floor_label = '2F') = 1
        AND count(*) FILTER (WHERE p.purpose = 'floor' AND p.floor_label = '3F') = 1
        AND (
          SELECT count(DISTINCT t.floor_label)
          FROM public.tables t
          WHERE t.restaurant_id = v_store
        ) >= 3
      FROM public.printer_destinations p
      WHERE p.restaurant_id = v_store
        AND p.is_active
    ),
    'kitchen + 1F/2F/3F floor destinations'
  );

  PERFORM pg_temp.add_result(
    'configured fixture store has no NO_DESTINATION print jobs',
    NOT EXISTS (
      SELECT 1
      FROM public.print_jobs
      WHERE restaurant_id = v_store
        AND last_error = 'NO_DESTINATION'
    ),
    'NO_DESTINATION would be a Gate 2 regression'
  );

  UPDATE public.tables
  SET status = 'available'
  WHERE id = v_table_2f;

  v_qr_result := public.qr_place_order(
    'gate3-2f-token-20260709',
    jsonb_build_array(
      jsonb_build_object('menu_item_id', v_menu_item, 'quantity', 1)
    ),
    v_qr_client
  );
  v_qr_order := (v_qr_result->>'order_id')::uuid;

  PERFORM pg_temp.add_result(
    'QR order lands on the token table and creates confirmation print',
    EXISTS (
      SELECT 1
      FROM public.orders o
      JOIN public.print_jobs pj ON pj.order_id = o.id
      WHERE o.id = v_qr_order
        AND o.restaurant_id = v_store
        AND o.table_id = v_table_2f
        AND o.order_source = 'qr'
        AND pj.copy_type = 'confirmation'
        AND pj.destination_id IS NOT NULL
        AND COALESCE(pj.last_error, '') <> 'NO_DESTINATION'
    ),
    COALESCE(v_qr_result::text, 'null')
  );

  v_qr_replay := public.qr_place_order(
    'gate3-2f-token-20260709',
    jsonb_build_array(
      jsonb_build_object('menu_item_id', v_menu_item, 'quantity', 1)
    ),
    v_qr_client
  );

  PERFORM pg_temp.add_result(
    'QR replay keeps the same client order idempotent',
    (v_qr_replay->>'order_id')::uuid = v_qr_order
      AND (
        SELECT count(*)
        FROM public.qr_order_batches
        WHERE client_order_id = v_qr_client
          AND order_id = v_qr_order
      ) = 1,
    COALESCE(v_qr_replay::text, 'null')
  );

  INSERT INTO public.restaurants (
    id, name, address, slug, operation_mode, is_active,
    brand_id, store_type, tax_entity_id, vat_pricing_mode
  ) VALUES (
    v_other_store,
    'Pilot Gate3 Isolation Store',
    'Pilot fixture only - cross-store guard',
    'pilot-gate3-isolation',
    'standard',
    true,
    v_brand,
    'direct',
    v_tax_entity,
    'exclusive'
  )
  ON CONFLICT (id) DO UPDATE SET
    is_active = true,
    brand_id = EXCLUDED.brand_id,
    tax_entity_id = EXCLUDED.tax_entity_id;

  INSERT INTO public.tables (
    id, restaurant_id, table_number, seat_count, status, floor_label
  ) VALUES (
    v_other_table, v_other_store, 'G3-X-01', 2, 'occupied', '1F'
  )
  ON CONFLICT (id) DO UPDATE SET
    status = 'occupied',
    floor_label = '1F';

  INSERT INTO public.orders (
    id, restaurant_id, table_id, status, guest_count, notes, order_source
  ) VALUES (
    v_other_order,
    v_other_store,
    v_other_table,
    'serving',
    1,
    'Pilot Gate3 cross-store guard row',
    'staff'
  )
  ON CONFLICT (id) DO UPDATE SET
    status = 'serving',
    restaurant_id = EXCLUDED.restaurant_id,
    table_id = EXCLUDED.table_id;

  PERFORM pg_temp.act_as(v_waiter_auth);
  v_denied := false;
  BEGIN
    PERFORM public.search_active_order_for_cashier(
      v_other_store,
      substring(v_other_order::text from 1 for 8)
    );
  EXCEPTION WHEN OTHERS THEN
    v_denied := SQLERRM LIKE '%STORE_ACCESS_DENIED%';
  END;
  PERFORM pg_temp.add_result(
    'cross-store cashier search is denied for fixture waiter',
    v_denied,
    'search_active_order_for_cashier against isolation store'
  );

  INSERT INTO public.orders (
    id, restaurant_id, table_id, sales_channel, status,
    guest_count, created_by, notes, order_purpose, order_source, created_at
  ) VALUES (
    v_close_order,
    v_store,
    v_table_1f,
    'dine_in',
    'completed',
    1,
    v_waiter_auth,
    'Pilot Gate3 rollback daily close order',
    'customer',
    'staff',
    now()
  )
  ON CONFLICT (id) DO UPDATE SET
    status = 'completed',
    created_at = now();

  INSERT INTO public.payments (
    id, restaurant_id, order_id, amount, method, is_revenue,
    processed_by, notes, amount_portion, created_at
  ) VALUES (
    v_close_payment,
    v_store,
    v_close_order,
    77000,
    'CASH',
    true,
    v_cashier_auth,
    'Pilot Gate3 rollback payment',
    77000,
    now()
  )
  ON CONFLICT (id) DO UPDATE SET
    amount = 77000,
    amount_portion = 77000,
    created_at = now();

  PERFORM pg_temp.act_as(v_admin_auth);
  v_adjustment := public.record_payment_adjustment(
    v_close_payment,
    'refund',
    1000,
    'Pilot Gate3 rollback refund guard'
  );

  v_over_refund_blocked := false;
  BEGIN
    PERFORM public.record_payment_adjustment(
      v_close_payment,
      'refund',
      999999999,
      'Pilot Gate3 over-refund guard'
    );
  EXCEPTION WHEN OTHERS THEN
    v_over_refund_blocked := true;
  END;

  PERFORM pg_temp.add_result(
    'refund path records append-only row and blocks over-refund',
    v_adjustment.payment_id = v_close_payment
      AND v_adjustment.adjustment_type = 'refund'
      AND v_adjustment.amount = 1000
      AND v_over_refund_blocked,
    'record_payment_adjustment rollback path'
  );

  DELETE FROM public.daily_closings
  WHERE restaurant_id = v_store
    AND closing_date = v_current_date;

  v_close_result := public.create_daily_closing(
    v_store,
    'Pilot Gate3 rollback daily close audit'
  );

  PERFORM pg_temp.add_result(
    'daily close RPC captures same-day payment totals',
    (v_close_result->>'closing_date')::date = v_current_date
      AND (v_close_result->>'payments_total')::numeric >= 77000
      AND (v_close_result->>'payments_count')::int >= 1,
    COALESCE(v_close_result::text, 'null')
  );
END;
$audit$;

DO $report$
DECLARE
  v_failures int;
  v_report text;
BEGIN
  SELECT
    count(*) FILTER (WHERE NOT ok),
    string_agg(
      (CASE WHEN ok THEN 'PASS ' ELSE 'FAIL ' END) || scenario ||
        CASE WHEN ok THEN '' ELSE ' :: ' || COALESCE(detail, '') END,
      ' | '
      ORDER BY scenario
    )
  INTO v_failures, v_report
  FROM _pilot_gate3_results;

  IF v_failures > 0 THEN
    RAISE EXCEPTION 'PILOT_GATE3_OPERATIONAL_AUDIT fail=% >>> %',
      v_failures,
      v_report;
  END IF;

  RAISE NOTICE 'PILOT_GATE3_OPERATIONAL_AUDIT_READY %', v_report;
END;
$report$;

SELECT scenario, ok, detail
FROM _pilot_gate3_results
ORDER BY scenario;

ROLLBACK;
