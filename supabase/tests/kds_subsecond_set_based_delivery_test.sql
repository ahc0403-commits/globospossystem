\set ON_ERROR_STOP on

BEGIN;

DO $test$
DECLARE
  v_store uuid;
  v_auth uuid := gen_random_uuid();
  v_user uuid;
  v_session uuid := gen_random_uuid();
  v_assignment uuid := gen_random_uuid();
  v_menu uuid := gen_random_uuid();
  v_order uuid := gen_random_uuid();
  v_order_item uuid := gen_random_uuid();
  v_item uuid;
  v_queue uuid;
  v_floor text;
  v_started_at timestamptz;
  v_kitchen_elapsed interval;
  v_tray_elapsed interval;
  v_floor_elapsed interval;
  v_allocations jsonb;
BEGIN
  SELECT id INTO v_store FROM public.restaurants
  WHERE is_active = true ORDER BY created_at, id LIMIT 1;
  IF v_store IS NULL THEN
    RAISE EXCEPTION 'KDS_SUBSECOND_TEST_NEEDS_SEEDED_STORE';
  END IF;

  INSERT INTO auth.users(id, email)
  VALUES (v_auth, 'kds-scale@internal.invalid');
  INSERT INTO public.users(auth_id, restaurant_id, role, full_name, is_active)
  VALUES (v_auth, v_store, 'emergency_station', 'KDS scale', true)
  RETURNING id INTO v_user;
  INSERT INTO public.user_store_access(
    user_id, store_id, is_primary, is_active, source_type
  ) VALUES (v_user, v_store, true, true, 'direct');
  INSERT INTO public.restaurant_settings(restaurant_id, fulfillment_mode)
  VALUES (v_store, 'paperless')
  ON CONFLICT (restaurant_id) DO UPDATE SET fulfillment_mode = 'paperless';
  INSERT INTO public.emergency_fulfillment_sessions(
    id, restaurant_id, reason
  ) VALUES (v_session, v_store, 'KDS scale contract');
  INSERT INTO public.emergency_station_assignments(
    id, restaurant_id, user_id, station_type, is_active
  ) VALUES (v_assignment, v_store, v_user, 'kitchen', true);
  INSERT INTO public.menu_items(
    id, restaurant_id, name, name_ko, name_vi, name_en, price
  ) VALUES (
    v_menu, v_store, 'Scale menu', '대량 메뉴', 'Món quy mô',
    'Scale menu', 10000
  );
  INSERT INTO public.orders(
    id, restaurant_id, status, fulfillment_mode_snapshot, created_at
  ) VALUES (v_order, v_store, 'serving', 'paperless', now());
  INSERT INTO public.order_items(
    id, restaurant_id, order_id, menu_item_id, display_name, label,
    quantity, unit_price, status, fulfillment_mode_snapshot, created_at
  ) VALUES (
    v_order_item, v_store, v_order, v_menu, '대량 메뉴', '대량 메뉴',
    1000, 10000, 'ready', 'paperless', now()
  );

  SELECT item.id, item.queue_id, queue.floor_label
  INTO v_item, v_queue, v_floor
  FROM public.emergency_fulfillment_items item
  JOIN public.emergency_order_queue queue ON queue.id = item.queue_id
  WHERE item.order_item_id = v_order_item;
  IF v_item IS NULL OR v_queue IS NULL THEN
    RAISE EXCEPTION 'KDS_SUBSECOND_FIXTURE_CAPTURE_FAILED';
  END IF;

  PERFORM set_config(
    'request.jwt.claims',
    json_build_object('sub', v_auth, 'role', 'authenticated')::text,
    true
  );
  v_allocations := jsonb_build_array(jsonb_build_object(
    'item_id', v_item, 'queue_id', v_queue,
    'source_kind', 'base', 'quantity', 1000
  ));

  v_started_at := clock_timestamp();
  PERFORM public.kds_complete_kitchen_batch_v1(
    gen_random_uuid(), v_allocations
  );
  v_kitchen_elapsed := clock_timestamp() - v_started_at;

  UPDATE public.emergency_station_assignments
  SET station_type = 'tray', floor_label = NULL WHERE id = v_assignment;
  v_started_at := clock_timestamp();
  PERFORM public.kds_dispatch_tray_floor_batch_v1(
    gen_random_uuid(), v_floor, v_allocations
  );
  v_tray_elapsed := clock_timestamp() - v_started_at;

  UPDATE public.emergency_station_assignments
  SET station_type = 'floor', floor_label = v_floor WHERE id = v_assignment;
  v_started_at := clock_timestamp();
  PERFORM public.kds_complete_customer_delivery_batch_v1(
    gen_random_uuid(), v_allocations
  );
  v_floor_elapsed := clock_timestamp() - v_started_at;

  IF v_kitchen_elapsed >= interval '2 seconds'
     OR v_tray_elapsed >= interval '2 seconds'
     OR v_floor_elapsed >= interval '2 seconds' THEN
    RAISE EXCEPTION
      'KDS_SUBSECOND_LATENCY_BUDGET_EXCEEDED kitchen=% tray=% floor=%',
      v_kitchen_elapsed, v_tray_elapsed, v_floor_elapsed;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.emergency_fulfillment_items
    WHERE id = v_item
      AND kitchen_done_quantity = 1000
      AND tray_dispatched_quantity = 1000
      AND floor_served_quantity = 1000
  ) OR (SELECT count(*) FROM public.emergency_fulfillment_events
        WHERE order_item_id = v_order_item
          AND stage IN ('kitchen_done', 'tray_dispatched', 'floor_served')) <> 3
     OR (SELECT count(*) FROM public.emergency_tray_ready_lots
         WHERE source_kind = 'base' AND source_id = v_item) <> 1
     OR (SELECT count(*) FROM public.emergency_floor_ready_lots
         WHERE source_kind = 'base' AND source_id = v_item) <> 1 THEN
    RAISE EXCEPTION 'KDS_SUBSECOND_SET_BASED_RESULT_INVALID';
  END IF;

  RAISE NOTICE
    'PASS: 1000-unit set-based path kitchen=%, tray=%, floor=%',
    v_kitchen_elapsed, v_tray_elapsed, v_floor_elapsed;
END;
$test$;

ROLLBACK;
