-- Runtime contract for physical-floor menu timing drill-down.
-- Run after all migrations with:
--   psql "$DB_URL" -v ON_ERROR_STOP=1 -f supabase/tests/paperless_menu_timing_detail_test.sql

BEGIN;

DO $test$
DECLARE
  v_result jsonb;
  v_next_floor_seconds numeric;
  v_next_sample_key text;
  v_physical_floor text;
  v_floor_inferred boolean;
BEGIN
  INSERT INTO public.companies(id, name)
  VALUES ('c2000000-0000-4000-8000-000000000001', 'Floor detail test company');

  INSERT INTO public.brand_master(id, company_id, name, type)
  VALUES (
    'c2000000-0000-4000-8000-000000000002',
    'c2000000-0000-4000-8000-000000000001',
    'Floor detail master',
    'internal'
  );

  INSERT INTO public.tax_entity(id, tax_code, name, owner_type)
  VALUES (
    'c2000000-0000-4000-8000-000000000003',
    'FLOOR-DETAIL-TEST-20260917',
    'Floor detail tax entity',
    'internal'
  );

  INSERT INTO public.brands(id, code, name, brand_master_id)
  VALUES (
    'c2000000-0000-4000-8000-000000000004',
    'floor_detail_test_20260917',
    'Floor detail brand',
    'c2000000-0000-4000-8000-000000000002'
  );

  INSERT INTO public.restaurants(id, name, slug, brand_id, tax_entity_id)
  VALUES (
    'c2000000-0000-4000-8000-000000000005',
    'Floor detail store',
    'floor-detail-test-20260917',
    'c2000000-0000-4000-8000-000000000004',
    'c2000000-0000-4000-8000-000000000003'
  );

  INSERT INTO auth.users(id, email)
  VALUES (
    'c2000000-0000-4000-8000-0000000000a1',
    'floor-detail-admin@globos.test'
  );

  INSERT INTO public.users(
    id, auth_id, restaurant_id, primary_store_id, brand_id, role, full_name
  ) VALUES (
    'c2000000-0000-4000-8000-0000000000b1',
    'c2000000-0000-4000-8000-0000000000a1',
    'c2000000-0000-4000-8000-000000000005',
    'c2000000-0000-4000-8000-000000000005',
    'c2000000-0000-4000-8000-000000000004',
    'store_admin',
    'Floor Detail Manager'
  );

  INSERT INTO public.tables(
    id, restaurant_id, table_number, floor_label, status
  ) VALUES
    (
      'c2000000-0000-4000-8000-000000000010',
      'c2000000-0000-4000-8000-000000000005',
      '301',
      '3F',
      'occupied'
    ),
    (
      'c2000000-0000-4000-8000-000000000011',
      'c2000000-0000-4000-8000-000000000005',
      '201',
      '2F',
      'occupied'
    );

  INSERT INTO public.orders(
    id, restaurant_id, table_id, status, created_by, created_at
  ) VALUES
    (
      'c2000000-0000-4000-8000-000000000020',
      'c2000000-0000-4000-8000-000000000005',
      'c2000000-0000-4000-8000-000000000010',
      'serving',
      'c2000000-0000-4000-8000-0000000000a1',
      '2026-09-17 05:00:00+00'
    ),
    (
      'c2000000-0000-4000-8000-000000000021',
      'c2000000-0000-4000-8000-000000000005',
      'c2000000-0000-4000-8000-000000000011',
      'serving',
      'c2000000-0000-4000-8000-0000000000a1',
      '2026-09-17 06:00:00+00'
    );

  INSERT INTO public.menu_items(id, restaurant_id, name, price)
  VALUES (
    'c2000000-0000-4000-8000-000000000030',
    'c2000000-0000-4000-8000-000000000005',
    'Floor detail noodle',
    50000
  );

  INSERT INTO public.order_items(
    id, restaurant_id, order_id, menu_item_id, item_type, label, display_name,
    unit_price, quantity, status, paying_amount_inc_tax, created_at
  ) VALUES
    (
      'c2000000-0000-4000-8000-000000000040',
      'c2000000-0000-4000-8000-000000000005',
      'c2000000-0000-4000-8000-000000000020',
      'c2000000-0000-4000-8000-000000000030',
      'menu_item',
      'Floor detail noodle',
      'Floor detail noodle',
      50000,
      1,
      'served',
      50000,
      '2026-09-17 05:00:00+00'
    ),
    (
      'c2000000-0000-4000-8000-000000000041',
      'c2000000-0000-4000-8000-000000000005',
      'c2000000-0000-4000-8000-000000000021',
      'c2000000-0000-4000-8000-000000000030',
      'menu_item',
      'Floor detail noodle',
      'Floor detail noodle',
      50000,
      1,
      'served',
      50000,
      '2026-09-17 06:00:00+00'
    );

  INSERT INTO public.emergency_fulfillment_sessions(
    id, restaurant_id, reason
  ) VALUES (
    'c2000000-0000-4000-8000-000000000050',
    'c2000000-0000-4000-8000-000000000005',
    'Floor detail runtime test'
  );

  -- 3F is intentionally routed through the 2F KDS station. The trigger must
  -- preserve 3F as the physical table floor for analytics.
  INSERT INTO public.emergency_order_queue(
    id, session_id, restaurant_id, order_id, queue_no,
    table_number, floor_label, created_at
  ) VALUES
    (
      'c2000000-0000-4000-8000-000000000060',
      'c2000000-0000-4000-8000-000000000050',
      'c2000000-0000-4000-8000-000000000005',
      'c2000000-0000-4000-8000-000000000020',
      1,
      '301',
      '2F',
      '2026-09-17 05:00:00+00'
    ),
    (
      'c2000000-0000-4000-8000-000000000061',
      'c2000000-0000-4000-8000-000000000050',
      'c2000000-0000-4000-8000-000000000005',
      'c2000000-0000-4000-8000-000000000021',
      2,
      '201',
      '2F',
      '2026-09-17 06:00:00+00'
    );

  SELECT physical_floor_label, physical_floor_inferred
  INTO v_physical_floor, v_floor_inferred
  FROM public.emergency_order_queue
  WHERE id = 'c2000000-0000-4000-8000-000000000060';

  IF v_physical_floor <> '3F' OR v_floor_inferred THEN
    RAISE EXCEPTION 'Physical floor snapshot mismatch: %, %',
      v_physical_floor, v_floor_inferred;
  END IF;

  INSERT INTO public.emergency_fulfillment_items(
    id, session_id, restaurant_id, queue_id, order_id, order_item_id,
    source_quantity, ordered_quantity, kitchen_done_quantity,
    tray_received_quantity, tray_dispatched_quantity, floor_served_quantity
  ) VALUES
    (
      'c2000000-0000-4000-8000-000000000070',
      'c2000000-0000-4000-8000-000000000050',
      'c2000000-0000-4000-8000-000000000005',
      'c2000000-0000-4000-8000-000000000060',
      'c2000000-0000-4000-8000-000000000020',
      'c2000000-0000-4000-8000-000000000040',
      1, 1, 1, 1, 1, 1
    ),
    (
      'c2000000-0000-4000-8000-000000000071',
      'c2000000-0000-4000-8000-000000000050',
      'c2000000-0000-4000-8000-000000000005',
      'c2000000-0000-4000-8000-000000000061',
      'c2000000-0000-4000-8000-000000000021',
      'c2000000-0000-4000-8000-000000000041',
      1, 1, 1, 1, 1, 1
    );

  INSERT INTO public.emergency_fulfillment_events(
    event_id, session_id, restaurant_id, order_id, order_item_id,
    stage, delta, created_at
  ) VALUES
    (
      'c2000000-0000-4000-8000-000000000080',
      'c2000000-0000-4000-8000-000000000050',
      'c2000000-0000-4000-8000-000000000005',
      'c2000000-0000-4000-8000-000000000020',
      'c2000000-0000-4000-8000-000000000040',
      'kitchen_done', 1, '2026-09-17 05:10:00+00'
    ),
    (
      'c2000000-0000-4000-8000-000000000081',
      'c2000000-0000-4000-8000-000000000050',
      'c2000000-0000-4000-8000-000000000005',
      'c2000000-0000-4000-8000-000000000020',
      'c2000000-0000-4000-8000-000000000040',
      'tray_dispatched', 1, '2026-09-17 05:11:00+00'
    ),
    (
      'c2000000-0000-4000-8000-000000000082',
      'c2000000-0000-4000-8000-000000000050',
      'c2000000-0000-4000-8000-000000000005',
      'c2000000-0000-4000-8000-000000000020',
      'c2000000-0000-4000-8000-000000000040',
      'floor_served', 1, '2026-09-17 05:21:00+00'
    ),
    (
      'c2000000-0000-4000-8000-000000000083',
      'c2000000-0000-4000-8000-000000000050',
      'c2000000-0000-4000-8000-000000000005',
      'c2000000-0000-4000-8000-000000000021',
      'c2000000-0000-4000-8000-000000000041',
      'kitchen_done', 1, '2026-09-17 06:10:00+00'
    ),
    (
      'c2000000-0000-4000-8000-000000000084',
      'c2000000-0000-4000-8000-000000000050',
      'c2000000-0000-4000-8000-000000000005',
      'c2000000-0000-4000-8000-000000000021',
      'c2000000-0000-4000-8000-000000000041',
      'tray_dispatched', 1, '2026-09-17 06:11:00+00'
    ),
    (
      'c2000000-0000-4000-8000-000000000085',
      'c2000000-0000-4000-8000-000000000050',
      'c2000000-0000-4000-8000-000000000005',
      'c2000000-0000-4000-8000-000000000021',
      'c2000000-0000-4000-8000-000000000041',
      'floor_served', 1, '2026-09-17 06:12:00+00'
    );

  PERFORM set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub', 'c2000000-0000-4000-8000-0000000000a1',
      'role', 'authenticated'
    )::text,
    true
  );
  PERFORM set_config(
    'request.jwt.claim.sub',
    'c2000000-0000-4000-8000-0000000000a1',
    true
  );

  v_result := public.get_paperless_menu_timing_detail(
    'c2000000-0000-4000-8000-000000000005',
    '2026-09-17 00:00:00+00',
    '2026-09-18 00:00:00+00',
    'c2000000-0000-4000-8000-000000000030',
    NULL,
    1,
    NULL,
    NULL
  );

  IF jsonb_array_length(v_result -> 'floor_summaries') <> 2
     OR v_result #>> '{floor_summaries,0,physical_floor_label}' <> '3F'
     OR (v_result #>> '{floor_summaries,0,average_floor_seconds}')::integer <> 600
     OR v_result #>> '{samples,0,physical_floor_label}' <> '3F'
     OR v_result #>> '{samples,0,routing_floor_label}' <> '2F'
     OR (v_result #>> '{samples,0,floor_seconds}')::integer <> 600
     OR (v_result #>> '{overall_summary,floor_average_seconds}')::integer <> 330
     OR COALESCE((v_result ->> 'has_more')::boolean, false) IS NOT TRUE THEN
    RAISE EXCEPTION 'Menu floor detail aggregation mismatch: %', v_result;
  END IF;

  v_next_floor_seconds :=
    (v_result #>> '{next_cursor,floor_seconds}')::numeric;
  v_next_sample_key := v_result #>> '{next_cursor,sample_key}';
  v_result := public.get_paperless_menu_timing_detail(
    'c2000000-0000-4000-8000-000000000005',
    '2026-09-17 00:00:00+00',
    '2026-09-18 00:00:00+00',
    'c2000000-0000-4000-8000-000000000030',
    NULL,
    1,
    v_next_floor_seconds,
    v_next_sample_key
  );

  IF jsonb_array_length(v_result -> 'samples') <> 1
     OR v_result #>> '{samples,0,physical_floor_label}' <> '2F'
     OR (v_result #>> '{samples,0,floor_seconds}')::integer <> 60 THEN
    RAISE EXCEPTION 'Menu floor detail cursor mismatch: %', v_result;
  END IF;

  v_result := public.get_paperless_menu_timing_detail(
    'c2000000-0000-4000-8000-000000000005',
    '2026-09-17 00:00:00+00',
    '2026-09-18 00:00:00+00',
    'c2000000-0000-4000-8000-000000000030',
    '3F',
    50,
    NULL,
    NULL
  );

  IF (v_result ->> 'total_count')::integer <> 1
     OR v_result #>> '{samples,0,table_number}' <> '301' THEN
    RAISE EXCEPTION 'Menu floor detail filter mismatch: %', v_result;
  END IF;
END;
$test$;

ROLLBACK;
